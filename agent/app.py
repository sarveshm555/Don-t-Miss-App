import os
import uuid
import logging
from datetime import datetime, date, timezone
from fastapi import FastAPI, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from agent.models.reminder_schema import (
    AgentRequest,
    AgentResponse,
    ActionConfirmRequest,
    ActionConfirmResponse,
)
from agent.reminder_agent import ReminderAgent
from agent.services.action_router import ActionRouter
from agent.database.connection import check_db_connectivity, get_db_session, init_db
from agent.database.models import User, Reminder, ReminderChannel, ActionHistory
from agent.routes.auth_routes import auth_router
from agent.routes.reminder_routes import reminder_router
from agent.routes.twilio_routes import twilio_router
from agent.services.reminder_persistence import (
    parse_due_date,
    persist_confirmed_reminder_to_db,
)
from contextlib import asynccontextmanager
from agent.services.jwt_service import (
    get_current_user_optional,
    get_current_user_required,
    get_jwt_secret,
)

from agent.services.reminder_scheduler import get_reminder_scheduler

logger = logging.getLogger(__name__)

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Ensure required environment variables are set before accepting requests."""
    get_jwt_secret()
    try:
        init_db()
    except Exception as e:
        logger.warning(f"Could not auto-initialize DB tables on startup: {e}")
    scheduler = get_reminder_scheduler()
    scheduler.start()
    yield
    await scheduler.stop()

app = FastAPI(
    title="Don't Miss AI Assistant Backend",
    description="OpenAI API powered production backend for natural language reminder extraction with human confirmation, Supabase PostgreSQL persistence, and WhatsApp action routing",
    version="2.3.0",
    lifespan=lifespan,
)

app.include_router(auth_router)
app.include_router(reminder_router)
app.include_router(twilio_router)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

agent = ReminderAgent()
action_router = ActionRouter()

# Alias for backward compatibility
_persist_confirmed_reminder_to_db = persist_confirmed_reminder_to_db

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
async def create_reminder_proposal(
    request: AgentRequest,
    current_user: User | None = Depends(get_current_user_optional),
):
    if not request.prompt or not request.prompt.strip():
        raise HTTPException(status_code=400, detail="Prompt cannot be empty.")
    
    response = await agent.process_prompt_async(
        prompt=request.prompt,
        current_date=request.current_date,
        current_time=request.current_time,
    )
    return response

@app.post("/action/confirm", response_model=ActionConfirmResponse)
async def confirm_and_route_action(
    request: ActionConfirmRequest,
    current_user: User | None = Depends(get_current_user_optional),
):
    """Action Router endpoint: routes human-confirmed reminders to Android local notifications
    and/or WhatsApp via Twilio, and persists confirmed reminders to PostgreSQL.
    """
    effective_user_id = current_user.id if current_user else request.user_id
    effective_phone = request.user_phone_number or (current_user.phone_number if current_user else None)

    result = await action_router.route_confirmed_action(
        draft=request.draft,
        user_phone_number=effective_phone,
    )

    channels_dispatched = result.get("channels_dispatched", [])
    
    # Persist strictly after confirmation
    persisted_reminder_id = _persist_confirmed_reminder_to_db(
        draft=request.draft,
        user_phone_number=effective_phone,
        channels_dispatched=channels_dispatched,
        user_id=effective_user_id,
        reminder_id=request.reminder_id,
    )

    return ActionConfirmResponse(
        success=result.get("success", False),
        status=result.get("status", "ROUTED"),
        channels_dispatched=channels_dispatched,
        message=f"Action processed for channels: {', '.join(channels_dispatched)}",
        reminder_id=persisted_reminder_id,
    )

if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", "8000"))
    uvicorn.run(app, host="0.0.0.0", port=port, timeout_keep_alive=180)
