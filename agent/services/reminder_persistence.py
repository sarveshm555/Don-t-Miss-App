"""Persistence helper for human-confirmed reminders."""

import uuid
import logging
from datetime import datetime, date, timedelta, timezone
from typing import Optional, List
from sqlalchemy.orm import Session
from agent.database.connection import get_db_session
from agent.database.models import User, Reminder, ReminderChannel, ActionHistory

logger = logging.getLogger(__name__)

def parse_due_date(due_date_str: Optional[str]) -> Optional[date]:
    """Safely parse an incoming dueDate string into a Python date.

    Supports:
    - YYYY-MM-DD
    - YYYY-MM-DDTHH:MM:SS
    - YYYY-MM-DDTHH:MM:SS.mmm
    - ISO strings ending with Z or UTC offsets
    """
    if not due_date_str or not due_date_str.strip():
        return None
    clean_str = due_date_str.strip()
    if clean_str.endswith("Z") or clean_str.endswith("z"):
        clean_str = clean_str[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(clean_str).date()
    except (ValueError, TypeError):
        pass
    try:
        return date.fromisoformat(clean_str)
    except (ValueError, TypeError):
        pass
    try:
        return date.fromisoformat(clean_str.split("T")[0].split(" ")[0])
    except Exception:
        return None

def format_proposed_time(
    due_date_str: Optional[str],
    due_hour: Optional[int],
    due_minute: Optional[int],
) -> str:
    """Format extracted date and time into a friendly string."""
    time_part = ""
    if due_hour is not None:
        minute = due_minute if due_minute is not None else 0
        period = "AM" if due_hour < 12 else "PM"
        h = due_hour % 12
        if h == 0:
            h = 12
        time_part = f"{h}:{minute:02d} {period}"

    date_part = ""
    if due_date_str:
        d = parse_due_date(due_date_str)
        if d:
            today = date.today()
            if d == today:
                date_part = "Today"
            elif d == today + timedelta(days=1):
                date_part = "Tomorrow"
            else:
                date_part = d.strftime("%A, %b %d")
        else:
            date_part = due_date_str

    if date_part and time_part:
        return f"{date_part} at {time_part}"
    elif date_part:
        return date_part
    elif time_part:
        return f"At {time_part}"
    return "No deadline specified"

def persist_confirmed_reminder_to_db(
    draft,
    user_phone_number: Optional[str],
    channels_dispatched: List[str],
    user_id: Optional[str] = None,
    reminder_id: Optional[str] = None,
    session: Optional[Session] = None,
) -> Optional[str]:
    """Persist a human-confirmed reminder and record audit history in PostgreSQL.

    Strictly invoked AFTER human confirmation.
    """
    should_close = False
    if session is None:
        session = next(get_db_session())
        should_close = True

    try:
        # 1. Ensure user exists (by user_id, phone, or default guest user)
        user = None
        if user_id:
            user = session.query(User).filter_by(id=user_id).first()
        if not user and user_phone_number:
            user = session.query(User).filter_by(phone_number=user_phone_number).first()
        if not user:
            user = session.query(User).filter_by(email="guest@dontmiss.app").first()
        if not user:
            user = User(
                email="guest@dontmiss.app",
                password_hash="system_guest_account",
                full_name="Guest User",
                phone_number=user_phone_number,
            )
            session.add(user)
            session.commit()

        # 2. Parse due date safely across ISO 8601 date and datetime formats
        due_d = parse_due_date(getattr(draft, "dueDate", None))

        # 3. Create or update reminder record with status CONFIRMED
        target_id = reminder_id.strip() if reminder_id and reminder_id.strip() else None
        reminder = None
        if target_id:
            reminder = session.query(Reminder).filter_by(id=target_id).first()
        if reminder:
            reminder.title = draft.title
            reminder.description = draft.description
            reminder.due_date = due_d
            reminder.due_hour = getattr(draft, "dueHour", None)
            reminder.due_minute = getattr(draft, "dueMinute", None)
            reminder.priority = getattr(draft, "priority", None) or "medium"
            reminder.recurrence = getattr(draft, "recurrence", None) or "none"
            reminder.url = getattr(draft, "url", None)
            reminder.status = "CONFIRMED"
            reminder.updated_at = datetime.now(timezone.utc)
        else:
            reminder = Reminder(
                id=target_id or str(uuid.uuid4()),
                user_id=user.id,
                title=draft.title,
                description=draft.description,
                due_date=due_d,
                due_hour=getattr(draft, "dueHour", None),
                due_minute=getattr(draft, "dueMinute", None),
                priority=getattr(draft, "priority", None) or "medium",
                recurrence=getattr(draft, "recurrence", None) or "none",
                url=getattr(draft, "url", None),
                status="CONFIRMED",
                raw_prompt=getattr(draft, "rawPrompt", draft.title) or draft.title,
            )
            session.add(reminder)
        session.commit()

        # 4. Create reminder channels
        draft_channels = getattr(draft, "channels", None) or ["local"]
        for ch in draft_channels:
            ch_status = "DISPATCHED" if ch in channels_dispatched else "PENDING"
            channel_record = ReminderChannel(
                reminder_id=reminder.id,
                channel=ch,
                status=ch_status,
                dispatched_at=datetime.now(timezone.utc) if ch_status == "DISPATCHED" else None,
            )
            session.add(channel_record)

        # 5. Create action history record
        history = ActionHistory(
            user_id=user.id,
            reminder_id=reminder.id,
            action_type="CONFIRM_REMINDER",
            details=f"Channels: {channels_dispatched}",
            success=True,
        )
        session.add(history)
        session.commit()
        return reminder.id
    except Exception as e:
        logger.warning(f"Could not persist confirmed reminder to database: {e}")
        return None
    finally:
        if should_close:
            session.close()
