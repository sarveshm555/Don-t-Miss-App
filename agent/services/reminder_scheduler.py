"""Scheduled reminder processing service for Don't Miss.

Inspects database for due reminders configured with 'whatsapp' delivery channel
and dispatches them to the user's verified WhatsApp number via Twilio.
Enforces strict idempotency and avoids blocking FastAPI request handling.
"""

import os
import asyncio
import logging
from datetime import datetime, timezone
from typing import Optional, List, Dict, Any
from sqlalchemy.orm import Session

from agent.database.connection import get_db_session
from agent.database.models import Reminder, ReminderChannel, User, ActionHistory
from agent.services.twilio_whatsapp_service import TwilioWhatsAppService
from agent.services.timezone_service import reminder_due_to_utc, is_reminder_due_utc

logger = logging.getLogger(__name__)

class ReminderScheduler:
    """Lightweight, non-blocking scheduler for processing scheduled reminders."""

    def __init__(
        self,
        whatsapp_service: Optional[TwilioWhatsAppService] = None,
        polling_interval_seconds: int = 60,
    ):
        self.whatsapp_service = whatsapp_service or TwilioWhatsAppService()
        self.polling_interval_seconds = polling_interval_seconds
        self.is_running = False
        self._task: Optional[asyncio.Task] = None

    def is_reminder_due(self, reminder: Reminder, current_dt: datetime) -> bool:
        """Determines whether a reminder has reached or passed its scheduled due time.

        Evaluates accurately in UTC using due_timestamp_utc or converts local due_date/hour/minute
        using the reminder's associated timezone (defaulting to Asia/Kolkata).
        """
        # 1. Use stored UTC timestamp if available
        if getattr(reminder, "due_timestamp_utc", None) is not None:
            return is_reminder_due_utc(reminder.due_timestamp_utc, current_dt)

        # 2. Backward compatibility fallback: compute UTC timestamp on the fly
        if not reminder.due_date:
            return False

        user_tz = None
        if reminder.user and getattr(reminder.user, "timezone", None):
            user_tz = reminder.user.timezone

        tz_name = getattr(reminder, "timezone", None) or user_tz or "Asia/Kolkata"
        due_utc = reminder_due_to_utc(
            due_date=reminder.due_date,
            due_hour=reminder.due_hour,
            due_minute=reminder.due_minute,
            tz_name=tz_name,
        )
        if not due_utc:
            return False

        return is_reminder_due_utc(due_utc, current_dt)

    def process_due_reminders(
        self,
        db: Session,
        current_dt: Optional[datetime] = None,
    ) -> List[Dict[str, Any]]:
        """Processes all pending WhatsApp reminder channels that are currently due.
        
        Guarantees idempotency by transitioning ReminderChannel status from 'PENDING'
        to 'DISPATCHED', 'SKIPPED_UNVERIFIED', or 'FAILED'.
        """
        now = current_dt or datetime.now(timezone.utc)
        results: List[Dict[str, Any]] = []

        try:
            pending_channels = (
                db.query(ReminderChannel)
                .join(Reminder)
                .filter(
                    ReminderChannel.channel == "whatsapp",
                    ReminderChannel.status == "PENDING",
                    Reminder.status.in_(["CONFIRMED", "PROPOSED"]),
                )
                .all()
            )

            for channel_entry in pending_channels:
                reminder = channel_entry.reminder
                if not reminder:
                    continue

                if not self.is_reminder_due(reminder, now):
                    continue

                user = reminder.user

                # 1. Verification check: skip if user has no verified phone number
                if not user or not user.phone_number or not user.phone_verified:
                    logger.info(
                        "Skipping WhatsApp delivery for reminder %s: user has no verified phone number",
                        reminder.id,
                    )
                    channel_entry.status = "SKIPPED_UNVERIFIED"
                    channel_entry.dispatched_at = now
                    history = ActionHistory(
                        user_id=user.id if user else None,
                        reminder_id=reminder.id,
                        action_type="DISPATCH_WHATSAPP",
                        details="Skipped WhatsApp delivery: User has no verified phone number.",
                        success=False,
                    )
                    db.add(history)
                    db.commit()
                    results.append({
                        "reminder_id": reminder.id,
                        "status": "SKIPPED_UNVERIFIED",
                        "success": False,
                    })
                    continue

                # 2. Format time and dispatch via Twilio WhatsApp service
                time_str = (
                    f"{reminder.due_date} at "
                    f"{reminder.due_hour or 0:02d}:{reminder.due_minute or 0:02d}"
                )
                dispatch_res = self.whatsapp_service.send_reminder_sync(
                    to_number=user.phone_number,
                    title=reminder.title,
                    due_time=time_str,
                    description=reminder.description,
                    priority=reminder.priority,
                )

                if dispatch_res.get("success"):
                    channel_entry.status = "DISPATCHED"
                    channel_entry.dispatched_at = now
                    history = ActionHistory(
                        user_id=user.id,
                        reminder_id=reminder.id,
                        action_type="DISPATCH_WHATSAPP",
                        details=f"Sent to {user.phone_number}. SID: {dispatch_res.get('sid')}",
                        success=True,
                    )
                    db.add(history)
                    db.commit()
                    results.append({
                        "reminder_id": reminder.id,
                        "status": "DISPATCHED",
                        "success": True,
                        "sid": dispatch_res.get("sid"),
                    })
                else:
                    channel_entry.status = "FAILED"
                    channel_entry.dispatched_at = now
                    err_msg = dispatch_res.get("error") or dispatch_res.get("detail") or "Unknown error"
                    history = ActionHistory(
                        user_id=user.id,
                        reminder_id=reminder.id,
                        action_type="DISPATCH_WHATSAPP",
                        details=f"Twilio WhatsApp dispatch failed: {err_msg}",
                        success=False,
                    )
                    db.add(history)
                    db.commit()
                    results.append({
                        "reminder_id": reminder.id,
                        "status": "FAILED",
                        "success": False,
                        "error": err_msg,
                    })

        except Exception as e:
            db.rollback()
            logger.error("Error executing reminder scheduler loop: %s", e)

        return results

    async def _run_loop(self):
        """Asynchronous background loop that polls for due reminders."""
        logger.info("ReminderScheduler background loop started.")
        while self.is_running:
            try:
                session = next(get_db_session())
                try:
                    self.process_due_reminders(session)
                finally:
                    session.close()
            except Exception as e:
                logger.error("Unexpected error in reminder scheduler tick: %s", e)

            try:
                await asyncio.sleep(self.polling_interval_seconds)
            except asyncio.CancelledError:
                break
        logger.info("ReminderScheduler background loop stopped.")

    def start(self):
        """Starts the background scheduler task."""
        if not self.is_running:
            self.is_running = True
            try:
                loop = asyncio.get_running_loop()
                self._task = loop.create_task(self._run_loop())
            except RuntimeError:
                # If no running loop yet, task can be created when loop runs
                pass

    async def stop(self):
        """Stops the background scheduler task."""
        self.is_running = False
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

_scheduler_instance: Optional[ReminderScheduler] = None

def get_reminder_scheduler() -> ReminderScheduler:
    """Returns singleton ReminderScheduler instance."""
    global _scheduler_instance
    if _scheduler_instance is None:
        _scheduler_instance = ReminderScheduler()
    return _scheduler_instance
