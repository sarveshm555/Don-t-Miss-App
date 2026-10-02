import logging
from datetime import datetime, date
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from agent.database.connection import get_db_session
from agent.database.models import Reminder, ReminderChannel, User, generate_uuid, get_utc_now
from agent.models.reminder_schema import (
    ReminderCreateRequest,
    ReminderUpdateRequest,
    ReminderResponse,
)
from agent.services.jwt_service import get_current_user_required

logger = logging.getLogger(__name__)

reminder_router = APIRouter(prefix="/reminders", tags=["Reminders"])


def parse_due_date(due_date_str: Optional[str]) -> Optional[date]:
    """Safely parse an incoming dueDate string into a Python date."""
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


def _reminder_to_response(reminder: Reminder) -> ReminderResponse:
    """Serialize SQLAlchemy Reminder instance into standard Pydantic response."""
    channels = [rc.channel for rc in (reminder.channels or [])]
    if not channels:
        channels = ["local"]

    return ReminderResponse(
        id=reminder.id,
        user_id=reminder.user_id,
        title=reminder.title,
        description=reminder.description,
        due_date=reminder.due_date.isoformat() if reminder.due_date else None,
        due_hour=reminder.due_hour,
        due_minute=reminder.due_minute,
        priority=reminder.priority,
        recurrence=reminder.recurrence,
        url=reminder.url,
        status=reminder.status,
        completed_at=reminder.completed_at.isoformat() if reminder.completed_at else None,
        raw_prompt=reminder.raw_prompt,
        channels=channels,
        created_at=reminder.created_at.isoformat() if reminder.created_at else "",
        updated_at=reminder.updated_at.isoformat() if reminder.updated_at else "",
    )


@reminder_router.get("", response_model=List[ReminderResponse])
def get_reminders(
    current_user: User = Depends(get_current_user_required),
    db: Session = Depends(get_db_session),
):
    """Retrieve all reminders belonging ONLY to the authenticated user.
    
    Results are returned in deterministic order (newest updated first).
    """
    try:
        reminders = (
            db.query(Reminder)
            .filter(Reminder.user_id == current_user.id)
            .order_by(Reminder.updated_at.desc(), Reminder.created_at.desc())
            .all()
        )
        return [_reminder_to_response(r) for r in reminders]
    except Exception as e:
        logger.error(f"Error fetching reminders for user {current_user.id}: {e}")
        raise HTTPException(status_code=500, detail="Failed to fetch reminders.")


@reminder_router.post("", response_model=ReminderResponse, status_code=status.HTTP_201_CREATED)
def create_reminder(
    request: ReminderCreateRequest,
    current_user: User = Depends(get_current_user_required),
    db: Session = Depends(get_db_session),
):
    """Create or sync a reminder for the authenticated user.
    
    Always associates the reminder with the authenticated JWT user ID.
    Supports client-supplied ID for offline-first sync reconciliation.
    """
    due_d = None
    if request.due_date and request.due_date.strip():
        due_d = parse_due_date(request.due_date)
        if due_d is None:
            raise HTTPException(status_code=400, detail="Invalid due_date format. Expected YYYY-MM-DD.")

    reminder_id = request.id.strip() if request.id and request.id.strip() else generate_uuid()
    comp_dt = None
    if request.completed_at and request.completed_at.strip():
        try:
            clean_c = request.completed_at.strip().replace("Z", "+00:00").replace("z", "+00:00")
            comp_dt = datetime.fromisoformat(clean_c)
        except Exception:
            pass
    elif (request.status or "").upper() == "COMPLETED":
        comp_dt = get_utc_now()

    try:
        existing = db.query(Reminder).filter(Reminder.id == reminder_id).first()
        if existing:
            if existing.user_id != current_user.id:
                raise HTTPException(status_code=409, detail="Reminder ID collision.")
            # Idempotent upsert for sync
            existing.title = request.title
            existing.description = request.description
            existing.due_date = due_d
            existing.due_hour = request.due_hour
            existing.due_minute = request.due_minute
            existing.priority = request.priority or "medium"
            existing.recurrence = request.recurrence or "none"
            existing.url = request.url
            existing.status = request.status or "CONFIRMED"
            existing.completed_at = comp_dt
            existing.raw_prompt = request.raw_prompt or request.title
            existing.updated_at = get_utc_now()

            if request.channels is not None:
                existing_chs = db.query(ReminderChannel).filter_by(reminder_id=existing.id).all()
                existing_map = {rc.channel: rc for rc in existing_chs}
                for ch in request.channels:
                    if ch not in existing_map:
                        db.add(ReminderChannel(reminder_id=existing.id, channel=ch, status="PENDING"))
                for ch, rc in existing_map.items():
                    if ch not in request.channels and rc.status == "PENDING":
                        db.delete(rc)

            db.commit()
            db.refresh(existing)
            return _reminder_to_response(existing)

        new_reminder = Reminder(
            id=reminder_id,
            user_id=current_user.id,
            title=request.title,
            description=request.description,
            due_date=due_d,
            due_hour=request.due_hour,
            due_minute=request.due_minute,
            priority=request.priority or "medium",
            recurrence=request.recurrence or "none",
            url=request.url,
            status=request.status or "CONFIRMED",
            completed_at=comp_dt,
            raw_prompt=request.raw_prompt or request.title,
        )
        db.add(new_reminder)
        req_channels = request.channels if request.channels is not None else ["local", "whatsapp"]
        for ch in req_channels:
            db.add(ReminderChannel(reminder_id=new_reminder.id, channel=ch, status="PENDING"))
        db.commit()
        db.refresh(new_reminder)
        return _reminder_to_response(new_reminder)
    except HTTPException:
        raise
    except Exception as e:
        db.rollback()
        logger.error(f"Error creating reminder: {e}")
        raise HTTPException(status_code=500, detail="Failed to persist reminder to database.")


@reminder_router.put("/{reminder_id}", response_model=ReminderResponse)
def update_reminder(
    reminder_id: str,
    request: ReminderUpdateRequest,
    current_user: User = Depends(get_current_user_required),
    db: Session = Depends(get_db_session),
):
    """Update a reminder owned by the authenticated user."""
    try:
        reminder = (
            db.query(Reminder)
            .filter(Reminder.id == reminder_id, Reminder.user_id == current_user.id)
            .first()
        )
        if not reminder:
            raise HTTPException(status_code=404, detail="Reminder not found.")

        if request.due_date is not None:
            if request.due_date.strip():
                parsed = parse_due_date(request.due_date)
                if parsed is None:
                    raise HTTPException(status_code=400, detail="Invalid due_date format. Expected YYYY-MM-DD.")
                reminder.due_date = parsed
            else:
                reminder.due_date = None

        if request.title is not None:
            reminder.title = request.title
        if request.description is not None:
            reminder.description = request.description
        if request.due_hour is not None:
            reminder.due_hour = request.due_hour
        if request.due_minute is not None:
            reminder.due_minute = request.due_minute
        if request.priority is not None:
            reminder.priority = request.priority
        if request.recurrence is not None:
            reminder.recurrence = request.recurrence
        if request.url is not None:
            reminder.url = request.url
        if request.status is not None:
            reminder.status = request.status
        if request.completed_at is not None:
            if request.completed_at.strip():
                try:
                    clean_c = request.completed_at.strip().replace("Z", "+00:00").replace("z", "+00:00")
                    reminder.completed_at = datetime.fromisoformat(clean_c)
                except Exception:
                    pass
            else:
                reminder.completed_at = None
        elif (request.status or "").upper() == "COMPLETED" and not reminder.completed_at:
            reminder.completed_at = get_utc_now()
        elif (request.status or "").upper() == "CONFIRMED":
            reminder.completed_at = None

        if request.raw_prompt is not None:
            reminder.raw_prompt = request.raw_prompt

        if request.channels is not None:
            existing_chs = db.query(ReminderChannel).filter_by(reminder_id=reminder.id).all()
            existing_map = {rc.channel: rc for rc in existing_chs}
            for ch in request.channels:
                if ch not in existing_map:
                    db.add(ReminderChannel(reminder_id=reminder.id, channel=ch, status="PENDING"))
            for ch, rc in existing_map.items():
                if ch not in request.channels and rc.status == "PENDING":
                    db.delete(rc)

        reminder.updated_at = get_utc_now()
        db.commit()
        db.refresh(reminder)
        return _reminder_to_response(reminder)
    except HTTPException:
        raise
    except Exception as e:
        db.rollback()
        logger.error(f"Error updating reminder {reminder_id}: {e}")
        raise HTTPException(status_code=500, detail="Failed to update reminder.")


@reminder_router.delete("/{reminder_id}")
def delete_reminder(
    reminder_id: str,
    current_user: User = Depends(get_current_user_required),
    db: Session = Depends(get_db_session),
):
    """Delete a reminder owned by the authenticated user."""
    try:
        reminder = (
            db.query(Reminder)
            .filter(Reminder.id == reminder_id, Reminder.user_id == current_user.id)
            .first()
        )
        if not reminder:
            raise HTTPException(status_code=404, detail="Reminder not found.")

        db.delete(reminder)
        db.commit()
        return {"success": True, "message": "Reminder deleted successfully."}
    except HTTPException:
        raise
    except Exception as e:
        db.rollback()
        logger.error(f"Error deleting reminder {reminder_id}: {e}")
        raise HTTPException(status_code=500, detail="Failed to delete reminder.")
