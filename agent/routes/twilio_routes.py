"""Twilio WhatsApp webhook routes for Don't Miss.

Handles incoming WhatsApp messages, user phone verification validation,
conversational reminder proposals with human-in-the-loop YES/NO confirmations,
expiration handling, and Supabase PostgreSQL persistence.
"""

import os
import json
import logging
from datetime import datetime, timezone, timedelta
from typing import Optional, Set
from fastapi import APIRouter, Request, Response, Depends, HTTPException, status
from sqlalchemy.orm import Session
from twilio.twiml.messaging_response import MessagingResponse

from agent.database.connection import get_db_session
from agent.database.models import User, PendingWhatsAppConfirmation, ActionHistory
from agent.models.reminder_schema import ReminderDraft
from agent.services.reminder_persistence import (
    persist_confirmed_reminder_to_db,
    format_proposed_time,
)
from agent.routes.auth_routes import normalize_phone_number

logger = logging.getLogger(__name__)

twilio_router = APIRouter(tags=["Twilio WhatsApp"])

# Confirmation keyword sets (case-insensitive)
YES_KEYWORDS: Set[str] = {"yes", "y", "confirm", "ok"}
NO_KEYWORDS: Set[str] = {"no", "n", "cancel", "cancelled"}

# Confirmation proposal expiration duration
EXPIRATION_MINUTES = int(os.getenv("WHATSAPP_CONFIRMATION_EXPIRES_MINUTES", "15"))

_agent_instance = None

def get_reminder_agent():
    """Lazily load or return configured ReminderAgent."""
    global _agent_instance
    if _agent_instance is None:
        from agent.reminder_agent import ReminderAgent
        _agent_instance = ReminderAgent()
    return _agent_instance

def set_reminder_agent(custom_agent):
    """Allows test suites to inject a mocked ReminderAgent."""
    global _agent_instance
    _agent_instance = custom_agent

def _validate_twilio_request(request: Request, form_data: dict) -> bool:
    """Validate Twilio request signature if TWILIO_VALIDATE_WEBHOOK is enabled."""
    should_validate = os.getenv("TWILIO_VALIDATE_WEBHOOK", "false").lower() in ("true", "1", "yes")
    if not should_validate:
        return True

    auth_token = os.getenv("TWILIO_WEBHOOK_AUTH_TOKEN") or os.getenv("TWILIO_AUTH_TOKEN")
    if not auth_token:
        logger.error("Twilio webhook validation enabled but no auth token configured.")
        return False

    signature = request.headers.get("X-Twilio-Signature")
    if not signature:
        logger.warning("Missing X-Twilio-Signature header on webhook request.")
        return False

    try:
        from twilio.request_validator import RequestValidator
        validator = RequestValidator(auth_token)
        url = str(request.url)
        return validator.validate(url, form_data, signature)
    except Exception as e:
        logger.error("Error validating Twilio request signature: %s", e)
        return False

def _build_twiml_response(reply_text: str) -> Response:
    """Build a Twilio-compatible XML TwiML response."""
    twiml = MessagingResponse()
    twiml.message(reply_text)
    return Response(content=str(twiml), media_type="application/xml")

@twilio_router.post("/webhooks/twilio/whatsapp")
async def handle_twilio_whatsapp_webhook(
    request: Request,
    db: Session = Depends(get_db_session),
):
    """Webhook handling incoming Twilio WhatsApp messages."""
    content_type = request.headers.get("content-type", "")
    if content_type.startswith("application/json"):
        data = await request.json()
    else:
        form = await request.form()
        data = dict(form)

    # 1. Validate Twilio signature if configured
    if not _validate_twilio_request(request, data):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Invalid Twilio signature.",
        )

    # 2. Extract and normalize phone number & body
    raw_from = str(data.get("From", "")).strip()
    raw_body = str(data.get("Body", "")).strip()

    if not raw_from:
        return _build_twiml_response("Unable to identify sender phone number.")

    clean_phone_raw = raw_from.replace("whatsapp:", "").strip()
    normalized_phone = normalize_phone_number(clean_phone_raw)

    # 3. Associate phone number with verified user only
    # NEVER trust any user_id supplied in the request body.
    user = (
        db.query(User)
        .filter(User.phone_number == normalized_phone)
        .first()
    )

    if not user or not user.phone_verified:
        logger.info("Unverified/unregistered WhatsApp sender: %s", normalized_phone)
        return _build_twiml_response(
            "Your WhatsApp number is not linked to a Don't Miss account. "
            "Please verify your phone number in the app first."
        )

    # 4. Handle empty message
    if not raw_body:
        return _build_twiml_response(
            "Please send a reminder request, e.g., 'Remind me tomorrow at 9 AM to call Mom'."
        )

    body_lower = raw_body.lower()

    # 5. Handle YES / Confirmation
    if body_lower in YES_KEYWORDS:
        pending = (
            db.query(PendingWhatsAppConfirmation)
            .filter(
                PendingWhatsAppConfirmation.user_id == user.id,
                PendingWhatsAppConfirmation.phone_number == normalized_phone,
                PendingWhatsAppConfirmation.status == "PENDING",
            )
            .order_by(PendingWhatsAppConfirmation.created_at.desc())
            .first()
        )

        if not pending:
            # Check latest non-pending to provide helpful contextual feedback
            latest = (
                db.query(PendingWhatsAppConfirmation)
                .filter(
                    PendingWhatsAppConfirmation.user_id == user.id,
                    PendingWhatsAppConfirmation.phone_number == normalized_phone,
                )
                .order_by(PendingWhatsAppConfirmation.created_at.desc())
                .first()
            )
            if latest and latest.status == "CONFIRMED":
                return _build_twiml_response("This reminder has already been confirmed.")
            elif latest and latest.status == "EXPIRED":
                return _build_twiml_response(
                    "⌛ This reminder confirmation has expired. Please send the reminder request again."
                )
            return _build_twiml_response("You have no pending reminder confirmations.")

        # Check expiration
        now = datetime.now(timezone.utc)
        exp = pending.expires_at
        if exp.tzinfo is None:
            exp = exp.replace(tzinfo=timezone.utc)

        if now > exp:
            pending.status = "EXPIRED"
            db.commit()
            return _build_twiml_response(
                "⌛ This reminder confirmation has expired. Please send the reminder request again."
            )

        # Confirm and persist
        pending.status = "CONFIRMED"
        db.commit()

        try:
            draft_dict = json.loads(pending.proposed_draft)
            draft = ReminderDraft(**draft_dict)
        except Exception as e:
            logger.error("Failed to parse pending reminder draft: %s", e)
            return _build_twiml_response("Error processing proposal draft. Please try again.")

        reminder_id = persist_confirmed_reminder_to_db(
            draft=draft,
            user_phone_number=normalized_phone,
            channels_dispatched=["whatsapp"],
            user_id=user.id,
            session=db,
        )

        time_str = format_proposed_time(draft.dueDate, draft.dueHour, draft.dueMinute)
        return _build_twiml_response(
            f"✅ Reminder confirmed.\n\n{draft.title}\n{time_str}"
        )

    # 6. Handle NO / Cancel
    if body_lower in NO_KEYWORDS:
        pending = (
            db.query(PendingWhatsAppConfirmation)
            .filter(
                PendingWhatsAppConfirmation.user_id == user.id,
                PendingWhatsAppConfirmation.phone_number == normalized_phone,
                PendingWhatsAppConfirmation.status == "PENDING",
            )
            .order_by(PendingWhatsAppConfirmation.created_at.desc())
            .first()
        )

        if pending:
            pending.status = "CANCELLED"
            history = ActionHistory(
                user_id=user.id,
                action_type="CANCEL_REMINDER",
                details=f"WhatsApp reminder proposal cancelled by user",
                success=True,
            )
            db.add(history)
            db.commit()
            return _build_twiml_response("❌ Reminder cancelled.")
        else:
            return _build_twiml_response("No pending reminder to cancel.")

    # 7. Normal reminder request: Pass to existing ReminderAgent
    # Mark any prior pending confirmations as EXPIRED
    prior_pendings = (
        db.query(PendingWhatsAppConfirmation)
        .filter(
            PendingWhatsAppConfirmation.user_id == user.id,
            PendingWhatsAppConfirmation.phone_number == normalized_phone,
            PendingWhatsAppConfirmation.status == "PENDING",
        )
        .all()
    )
    for p in prior_pendings:
        p.status = "EXPIRED"
    db.commit()

    agent = get_reminder_agent()
    agent_response = await agent.process_prompt_async(prompt=raw_body)

    if agent_response.success and agent_response.proposal and agent_response.proposal.draft:
        draft = agent_response.proposal.draft
        channels = list(draft.channels or [])
        if "whatsapp" not in channels:
            channels.append("whatsapp")
        draft.channels = channels

        expires_at = datetime.now(timezone.utc) + timedelta(minutes=EXPIRATION_MINUTES)
        new_pending = PendingWhatsAppConfirmation(
            user_id=user.id,
            phone_number=normalized_phone,
            proposed_draft=json.dumps(draft.model_dump()),
            status="PENDING",
            expires_at=expires_at,
        )
        db.add(new_pending)

        history = ActionHistory(
            user_id=user.id,
            action_type="PROPOSE_REMINDER",
            details=f"WhatsApp reminder proposal: {draft.title}",
            success=True,
        )
        db.add(history)
        db.commit()

        time_str = format_proposed_time(draft.dueDate, draft.dueHour, draft.dueMinute)
        return _build_twiml_response(
            f"📋 I understood:\n\n{draft.title}\n{time_str}\n\nReply YES to confirm or NO to cancel."
        )

    # Could not parse or generate proposal
    return _build_twiml_response(
        "I couldn't identify a reminder from your message. "
        "Please specify what you'd like to be reminded about, e.g.: 'Remind me tomorrow at 6 PM to call Arun'."
    )
