import os
import logging
from datetime import datetime, date, timezone
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from agent.models.reminder_schema import (
    AgentRequest,
    AgentResponse,
    ActionConfirmRequest,
    ActionConfirmResponse,
)
from agent.reminder_agent import ReminderAgent
from agent.services.action_router import ActionRouter
from agent.database.connection import check_db_connectivity, get_db_session
from agent.database.models import User, Reminder, ReminderChannel, ActionHistory

logger = logging.getLogger(__name__)

app = FastAPI(
    title="Don't Miss AI Assistant Backend",
    description="OpenAI API powered production backend for natural language reminder extraction with human confirmation, Supabase PostgreSQL persistence, and WhatsApp action routing",
    version="2.2.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

agent = ReminderAgent()
action_router = ActionRouter()

def _persist_confirmed_reminder_to_db(draft, user_phone_number: str | None, channels_dispatched: list[str]) -> str | None:
    """Persist a human-confirmed reminder and record audit history in PostgreSQL.
    
    This function is strictly called AFTER human confirmation, never during proposal generation.
    """
    try:
        session = next(get_db_session())
        try:
            # 1. Ensure user exists (find by phone or default guest user)
            user = None
            if user_phone_number:
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

            # 2. Parse due date
            due_d = None
            if draft.dueDate:
                try:
                    due_d = date.fromisoformat(draft.dueDate)
                except Exception:
                    due_d = None

            # 3. Create reminder record with status CONFIRMED
            reminder = Reminder(
                user_id=user.id,
                title=draft.title,
                description=draft.description,
                due_date=due_d,
                due_hour=draft.dueHour,
                due_minute=draft.dueMinute,
                priority=draft.priority or "medium",
                recurrence=draft.recurrence or "none",
                url=draft.url,
                status="CONFIRMED",
                raw_prompt=draft.title,
            )
            session.add(reminder)
            session.commit()

            # 4. Create reminder channels
            for ch in (draft.channels or ["local"]):
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
        finally:
            session.close()
    except Exception as e:
        logger.warning(f"Could not persist confirmed reminder to database: {e}")
        return None

@app.get("/health")
def health_check():
    db_connected = check_db_connectivity()
    return {
        "status": "healthy",
        "ai_provider": "openai",
        "model": agent.model_id,
        "database": "connected" if db_connected else "disconnected",
        "configured": agent.is_configured,
    }

@app.post("/agent/reminder", response_model=AgentResponse)
async def create_reminder_proposal(request: AgentRequest):
    if not request.prompt or not request.prompt.strip():
        raise HTTPException(status_code=400, detail="Prompt cannot be empty.")
    
    response = await agent.process_prompt_async(
        prompt=request.prompt,
        current_date=request.current_date,
        current_time=request.current_time,
    )
    return response

@app.post("/action/confirm", response_model=ActionConfirmResponse)
async def confirm_and_route_action(request: ActionConfirmRequest):
    """Action Router endpoint: routes human-confirmed reminders to Android local notifications
    and/or WhatsApp via Twilio, and persists confirmed reminders to PostgreSQL.
    """
    result = await action_router.route_confirmed_action(
        draft=request.draft,
        user_phone_number=request.user_phone_number,
    )

    channels_dispatched = result.get("channels_dispatched", [])
    
    # Persist strictly after confirmation
    _persist_confirmed_reminder_to_db(
        draft=request.draft,
        user_phone_number=request.user_phone_number,
        channels_dispatched=channels_dispatched,
    )

    return ActionConfirmResponse(
        success=result.get("success", False),
        status=result.get("status", "ROUTED"),
        channels_dispatched=channels_dispatched,
        message=f"Action processed for channels: {', '.join(channels_dispatched)}",
    )

if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", "8000"))
    uvicorn.run(app, host="0.0.0.0", port=port, timeout_keep_alive=180)
