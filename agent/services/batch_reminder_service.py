"""Batch confirmation and creation service for Don't Miss.

Handles atomic multi-reminder confirmation, strict backend validation,
JWT-derived user isolation, database transaction rollback, dual idempotency,
and channel notification dispatch with accurate delivery status reporting.
"""

import json
import uuid
import hashlib
import logging
from datetime import datetime, date, timezone
from typing import List, Optional, Tuple, Dict, Any
from fastapi import HTTPException, status
from sqlalchemy.orm import Session

from agent.database.models import User, Reminder, ReminderChannel, ActionHistory, generate_uuid, get_utc_now
from agent.models.reminder_schema import (
    ReminderDraft,
    ReminderResponse,
    ReminderBatchRequest,
    ReminderBatchResponse,
    ReminderSchedulingStatus,
    BatchFailureItem,
)
from agent.services.reminder_persistence import parse_due_date, reminder_to_response
from agent.services.whatsapp_service import BaseWhatsAppService, TwilioWhatsAppService

logger = logging.getLogger(__name__)


def validate_draft(draft: ReminderDraft) -> None:
    """Validate an individual reminder draft before persistence.

    Raises HTTPException(400) on invalid or malicious data.
    """
    # 1. Title validation
    if not draft.title or not draft.title.strip():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Every reminder in the batch must have a non-empty title.",
        )
    if len(draft.title.strip()) > 255:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Reminder title '{draft.title[:30]}...' exceeds maximum length of 255 characters.",
        )

    # 2. Due date validation
    if draft.dueDate and draft.dueDate.strip():
        parsed = parse_due_date(draft.dueDate)
        if parsed is None:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid dueDate format for '{draft.title}'. Expected ISO 8601 (YYYY-MM-DD).",
            )

    # 3. Due hour validation
    if draft.dueHour is not None:
        if not isinstance(draft.dueHour, int) or draft.dueHour < 0 or draft.dueHour > 23:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid dueHour for '{draft.title}'. Must be between 0 and 23.",
            )

    # 4. Due minute validation
    if draft.dueMinute is not None:
        if not isinstance(draft.dueMinute, int) or draft.dueMinute < 0 or draft.dueMinute > 59:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid dueMinute for '{draft.title}'. Must be between 0 and 59.",
            )

    # 5. URL length validation
    if draft.url and len(draft.url) > 1024:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"URL for '{draft.title}' exceeds maximum length of 1024 characters.",
        )


def is_reminder_due_now(reminder: Reminder, current_dt: Optional[datetime] = None) -> bool:
    """Check if reminder has reached or passed its due date and time."""
    if not reminder.due_date:
        return False
    now = current_dt or datetime.now(timezone.utc)
    current_date = now.date()

    if current_date > reminder.due_date:
        return True
    elif current_date < reminder.due_date:
        return False

    rem_hour = reminder.due_hour if reminder.due_hour is not None else 0
    rem_minute = reminder.due_minute if reminder.due_minute is not None else 0
    if now.hour > rem_hour:
        return True
    elif now.hour == rem_hour and now.minute >= rem_minute:
        return True
    return False


class BatchReminderService:
    """Service orchestrating batch creation, transaction safety, and notification routing."""

    def __init__(self, whatsapp_service: Optional[BaseWhatsAppService] = None):
        self.whatsapp_service = whatsapp_service or TwilioWhatsAppService()

    def _generate_fingerprint(self, user_id: str, drafts: List[ReminderDraft]) -> str:
        """Generate deterministic fingerprint of batch payload for deduplication."""
        raw_repr = [
            {
                "title": (d.title or "").strip().lower(),
                "dueDate": d.dueDate,
                "dueHour": d.dueHour,
                "dueMinute": d.dueMinute,
                "priority": d.priority,
            }
            for d in drafts
        ]
        serialized = json.dumps(raw_repr, sort_keys=True)
        return hashlib.sha256(f"{user_id}:{serialized}".encode("utf-8")).hexdigest()[:32]

    def _check_idempotency(
        self,
        db: Session,
        current_user: User,
        idempotency_key: Optional[str],
        fingerprint: str,
    ) -> Optional[List[Reminder]]:
        """Check if this batch was already processed for this user."""
        recent_actions = (
            db.query(ActionHistory)
            .filter(
                ActionHistory.user_id == current_user.id,
                ActionHistory.action_type == "BATCH_CONFIRM",
                ActionHistory.success.is_(True),
            )
            .order_by(ActionHistory.created_at.desc())
            .limit(20)
            .all()
        )

        for action in recent_actions:
            if not action.details:
                continue
            try:
                data = json.loads(action.details)
                matched = False
                if idempotency_key and data.get("idempotency_key") == idempotency_key:
                    matched = True
                elif not idempotency_key and data.get("fingerprint") == fingerprint:
                    # Deduplicate exact matching batch within recent actions
                    matched = True

                if matched:
                    stored_ids = data.get("reminder_ids", [])
                    if stored_ids:
                        existing_reminders = (
                            db.query(Reminder)
                            .filter(
                                Reminder.id.in_(stored_ids),
                                Reminder.user_id == current_user.id,
                            )
                            .all()
                        )
                        if existing_reminders:
                            rem_map = {r.id: r for r in existing_reminders}
                            return [rem_map[rid] for rid in stored_ids if rid in rem_map]
            except Exception:
                continue
        return None

    async def process_batch(
        self,
        db: Session,
        current_user: User,
        request: ReminderBatchRequest,
        idempotency_key: Optional[str] = None,
    ) -> ReminderBatchResponse:
        """Process, validate, atomically persist, and schedule approved reminder drafts."""
        # 1. Enforce non-empty batch
        if not request.reminders or len(request.reminders) == 0:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Batch reminders list cannot be empty.",
            )

        # 2. Strict backend validation for every draft
        for draft in request.reminders:
            validate_draft(draft)

        # 3. Dual Idempotency check
        effective_key = idempotency_key or request.idempotency_key
        fingerprint = self._generate_fingerprint(current_user.id, request.reminders)
        existing_batch = self._check_idempotency(db, current_user, effective_key, fingerprint)

        if existing_batch:
            logger.info(
                f"Idempotent replay detected for user {current_user.id} with key {effective_key}"
            )
            scheduling_statuses: List[ReminderSchedulingStatus] = []
            for r in existing_batch:
                chs = [rc.channel for rc in (r.channels or [])] or ["local"]
                for ch in chs:
                    ch_rec = next((c for c in (r.channels or []) if c.channel == ch), None)
                    st = ch_rec.status if ch_rec else "PENDING"
                    scheduling_statuses.append(
                        ReminderSchedulingStatus(
                            reminder_id=r.id,
                            channel=ch,
                            status=st,
                            delivered=(st == "DISPATCHED"),
                            detail="Batch was previously processed (idempotent replay).",
                        )
                    )

            return ReminderBatchResponse(
                success=True,
                status="ALREADY_PROCESSED",
                total_requested=len(request.reminders),
                total_created=len(existing_batch),
                created_reminder_ids=[r.id for r in existing_batch],
                reminders=[reminder_to_response(r) for r in existing_batch],
                scheduling_status=scheduling_statuses,
                failures=[],
                idempotency_key=effective_key,
                message="Batch was previously processed (idempotent replay). No duplicate reminders created.",
            )

        # 4. Check for client-supplied ID collision across accounts
        for draft in request.reminders:
            if draft.id and draft.id.strip():
                cid = draft.id.strip()
                existing_rec = db.query(Reminder).filter(Reminder.id == cid).first()
                if existing_rec and existing_rec.user_id != current_user.id:
                    raise HTTPException(
                        status_code=status.HTTP_409_CONFLICT,
                        detail=f"Reminder ID collision: ID '{cid}' belongs to another account.",
                    )

        # 5. Database Transaction: Persist all reminders atomically
        persisted_reminders: List[Reminder] = []
        try:
            for draft in request.reminders:
                rem_id = (draft.id.strip() if draft.id and draft.id.strip() else generate_uuid())
                due_d = parse_due_date(draft.dueDate) if draft.dueDate else None
                priority = (draft.priority or "medium").lower()
                if priority not in ("low", "medium", "high"):
                    priority = "medium"
                recurrence = (draft.recurrence or "none").lower()
                if recurrence not in ("none", "daily", "weekly", "monthly"):
                    recurrence = "none"

                existing_rem = (
                    db.query(Reminder)
                    .filter(Reminder.id == rem_id, Reminder.user_id == current_user.id)
                    .first()
                )

                if existing_rem:
                    existing_rem.title = draft.title.strip()
                    existing_rem.description = draft.description
                    existing_rem.due_date = due_d
                    existing_rem.due_hour = draft.dueHour
                    existing_rem.due_minute = draft.dueMinute
                    existing_rem.priority = priority
                    existing_rem.recurrence = recurrence
                    existing_rem.url = draft.url
                    existing_rem.status = "CONFIRMED"
                    existing_rem.raw_prompt = draft.reasoning or draft.title
                    existing_rem.updated_at = get_utc_now()
                    target_rem = existing_rem
                else:
                    new_rem = Reminder(
                        id=rem_id,
                        user_id=current_user.id,
                        title=draft.title.strip(),
                        description=draft.description,
                        due_date=due_d,
                        due_hour=draft.dueHour,
                        due_minute=draft.dueMinute,
                        priority=priority,
                        recurrence=recurrence,
                        url=draft.url,
                        status="CONFIRMED",
                        raw_prompt=draft.reasoning or draft.title,
                    )
                    db.add(new_rem)
                    target_rem = new_rem

                # Channels handling
                req_channels = [
                    ch.lower().strip()
                    for ch in (draft.channels or ["local", "whatsapp"])
                    if ch.lower().strip() in ("local", "whatsapp")
                ]
                if not req_channels:
                    req_channels = ["local"]

                existing_chs = {rc.channel: rc for rc in (target_rem.channels or [])}
                for ch in req_channels:
                    if ch not in existing_chs:
                        db.add(
                            ReminderChannel(
                                reminder_id=target_rem.id,
                                channel=ch,
                                status="PENDING",
                            )
                        )

                persisted_reminders.append(target_rem)

            # Record ActionHistory with audit trail & idempotency
            history = ActionHistory(
                user_id=current_user.id,
                action_type="BATCH_CONFIRM",
                details=json.dumps(
                    {
                        "idempotency_key": effective_key,
                        "fingerprint": fingerprint,
                        "reminder_ids": [r.id for r in persisted_reminders],
                        "count": len(persisted_reminders),
                    }
                ),
                success=True,
            )
            db.add(history)

            # Atomic commit of the entire batch
            db.commit()

            # Refresh all persisted reminders
            for r in persisted_reminders:
                db.refresh(r)

        except HTTPException:
            db.rollback()
            raise
        except Exception as e:
            db.rollback()
            logger.error(f"Error persisting batch reminders: {e}", exc_info=True)
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Database transaction failed during batch reminder creation. All inserts rolled back.",
            )

        # 6. Notification Scheduling (Separated from Persistence)
        scheduling_statuses: List[ReminderSchedulingStatus] = []
        failures: List[BatchFailureItem] = []

        now_utc = datetime.now(timezone.utc)

        for rem in persisted_reminders:
            chs = [rc.channel for rc in (rem.channels or [])] or ["local"]
            for ch in chs:
                if ch == "local":
                    scheduling_statuses.append(
                        ReminderSchedulingStatus(
                            reminder_id=rem.id,
                            channel="local",
                            status="READY_FOR_DEVICE_SCHEDULE",
                            delivered=False,
                            detail="Saved to database; ready for device-side local alarm scheduling.",
                        )
                    )
                elif ch == "whatsapp":
                    if not current_user.phone_number:
                        scheduling_statuses.append(
                            ReminderSchedulingStatus(
                                reminder_id=rem.id,
                                channel="whatsapp",
                                status="SKIPPED",
                                delivered=False,
                                detail="User does not have a registered phone number.",
                            )
                        )
                        failures.append(
                            BatchFailureItem(
                                reminder_id=rem.id,
                                title=rem.title,
                                reason="No phone number configured for WhatsApp delivery.",
                                action_required="Add a verified phone number in your Profile to enable WhatsApp reminders.",
                            )
                        )
                    elif not current_user.phone_verified:
                        scheduling_statuses.append(
                            ReminderSchedulingStatus(
                                reminder_id=rem.id,
                                channel="whatsapp",
                                status="SKIPPED_UNVERIFIED",
                                delivered=False,
                                detail="User phone number is not verified.",
                            )
                        )
                        failures.append(
                            BatchFailureItem(
                                reminder_id=rem.id,
                                title=rem.title,
                                reason="Phone number is unverified.",
                                action_required="Verify your phone number in your Profile to enable WhatsApp notifications.",
                            )
                        )
                    else:
                        # User has a verified phone number
                        is_due = is_reminder_due_now(rem, now_utc)
                        if is_due:
                            # Immediate dispatch attempt for reminders due right now
                            time_str = f"{rem.due_date} at {rem.due_hour or 0:02d}:{rem.due_minute or 0:02d}"
                            try:
                                wa_result = await self.whatsapp_service.send_reminder(
                                    to_number=current_user.phone_number,
                                    title=rem.title,
                                    due_time=time_str,
                                    description=rem.description,
                                    priority=rem.priority,
                                )
                                if wa_result.get("success"):
                                    scheduling_statuses.append(
                                        ReminderSchedulingStatus(
                                            reminder_id=rem.id,
                                            channel="whatsapp",
                                            status="DISPATCHED",
                                            delivered=True,
                                            detail=f"Dispatched via WhatsApp (SID: {wa_result.get('sid')}).",
                                        )
                                    )
                                    ch_rec = (
                                        db.query(ReminderChannel)
                                        .filter_by(reminder_id=rem.id, channel="whatsapp")
                                        .first()
                                    )
                                    if ch_rec:
                                        ch_rec.status = "DISPATCHED"
                                        ch_rec.dispatched_at = datetime.now(timezone.utc)
                                        db.commit()
                                else:
                                    err_detail = (
                                        wa_result.get("error")
                                        or wa_result.get("detail")
                                        or "Twilio delivery failed"
                                    )
                                    scheduling_statuses.append(
                                        ReminderSchedulingStatus(
                                            reminder_id=rem.id,
                                            channel="whatsapp",
                                            status="FAILED",
                                            delivered=False,
                                            detail=f"WhatsApp delivery failed: {err_detail}",
                                        )
                                    )
                                    failures.append(
                                        BatchFailureItem(
                                            reminder_id=rem.id,
                                            title=rem.title,
                                            reason=f"WhatsApp delivery failed: {err_detail}",
                                            action_required="Ensure WhatsApp service is configured and recipient number is active.",
                                        )
                                    )
                                    ch_rec = (
                                        db.query(ReminderChannel)
                                        .filter_by(reminder_id=rem.id, channel="whatsapp")
                                        .first()
                                    )
                                    if ch_rec:
                                        ch_rec.status = "FAILED"
                                        db.commit()
                            except Exception as ex:
                                scheduling_statuses.append(
                                    ReminderSchedulingStatus(
                                        reminder_id=rem.id,
                                        channel="whatsapp",
                                        status="FAILED",
                                        delivered=False,
                                        detail=f"WhatsApp service error: {ex}",
                                    )
                                )
                                failures.append(
                                    BatchFailureItem(
                                        reminder_id=rem.id,
                                        title=rem.title,
                                        reason=f"WhatsApp service error: {ex}",
                                        action_required="Check server Twilio configuration.",
                                    )
                                )
                                ch_rec = (
                                    db.query(ReminderChannel)
                                    .filter_by(reminder_id=rem.id, channel="whatsapp")
                                    .first()
                                )
                                if ch_rec:
                                    ch_rec.status = "FAILED"
                                    db.commit()
                        else:
                            # Scheduled for future due time by background scheduler
                            due_str = (
                                f"{rem.due_date} at {rem.due_hour or 0:02d}:{rem.due_minute or 0:02d}"
                                if rem.due_date
                                else "future date"
                            )
                            scheduling_statuses.append(
                                ReminderSchedulingStatus(
                                    reminder_id=rem.id,
                                    channel="whatsapp",
                                    status="SCHEDULED",
                                    delivered=False,
                                    detail=f"Queued for automated WhatsApp delivery at {due_str}.",
                                )
                            )

        return ReminderBatchResponse(
            success=True,
            status="CONFIRMED",
            total_requested=len(request.reminders),
            total_created=len(persisted_reminders),
            created_reminder_ids=[r.id for r in persisted_reminders],
            reminders=[reminder_to_response(r) for r in persisted_reminders],
            scheduling_status=scheduling_statuses,
            failures=failures,
            idempotency_key=effective_key,
            message=f"Successfully confirmed and persisted {len(persisted_reminders)} reminder(s).",
        )
