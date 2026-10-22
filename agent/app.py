import os
import uuid
import base64
import logging
from datetime import datetime, date, timezone
from typing import Optional
from fastapi import FastAPI, HTTPException, Depends, Header, Request
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session
from agent.models.reminder_schema import (
    AgentRequest,
    AgentResponse,
    ActionConfirmRequest,
    ActionConfirmResponse,
    ReminderPlanRequest,
    ReminderPlanResponse,
    ReminderBatchRequest,
    ReminderBatchResponse,
    VoiceTranscribeRequest,
    VoiceTranscribeResponse,
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
from agent.services.batch_reminder_service import BatchReminderService
batch_reminder_service = BatchReminderService()
from agent.services.voice_transcription_service import VoiceTranscriptionService
voice_service = VoiceTranscriptionService()

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
        timezone=request.timezone,
    )
    return response

@app.post("/agent/reminders/plan", response_model=ReminderPlanResponse)
async def create_reminder_plan(
    request: ReminderPlanRequest,
    current_user: User | None = Depends(get_current_user_optional),
):
    """Multi-reminder planning endpoint.

    Extracts one or multiple structured reminder drafts from a single natural-language prompt.
    Validates all dates, times, and fields under the user's configured timezone (default: Asia/Kolkata).
    """
    if not request.prompt or not request.prompt.strip():
        raise HTTPException(status_code=400, detail="Prompt cannot be empty.")

    response = await agent.process_plan_async(request)
    return response

@app.post("/agent/reminders/batch", response_model=ReminderBatchResponse)
async def create_reminder_batch(
    request: ReminderBatchRequest,
    idempotency_header: Optional[str] = Header(None, alias="Idempotency-Key"),
    current_user: User = Depends(get_current_user_required),
    db: Session = Depends(get_db_session),
):
    """Batch confirmation and creation endpoint.

    Atomically validates, persists, and schedules multiple user-approved reminder drafts.
    Strictly derives user ID from authenticated JWT context and rolls back on any DB failure.
    """
    effective_idempotency = idempotency_header or request.idempotency_key
    return await batch_reminder_service.process_batch(
        db=db,
        current_user=current_user,
        request=request,
        idempotency_key=effective_idempotency,
    )

@app.post("/agent/voice/transcribe", response_model=VoiceTranscribeResponse)
async def transcribe_voice(
    request: Request,
    current_user: User | None = Depends(get_current_user_optional),
):
    """Voice transcription endpoint using backend OpenAI Whisper model.

    Accepts uploaded audio either via multipart/form-data ('file' field)
    or via JSON body with 'audio_base64' and 'filename'.
    Validates file formats (m4a, mp3, wav, webm, etc.), enforces size limits (25 MB),
    and strictly protects OpenAI credentials on backend.
    """
    content_type = (request.headers.get("content-type") or "").lower()
    filename = "audio.m4a"
    audio_bytes = b""
    language = None

    if "multipart/form-data" in content_type:
        form = await request.form()
        uploaded_file = form.get("file")
        if not uploaded_file:
            raise HTTPException(status_code=400, detail="Missing 'file' in multipart upload.")
        filename = getattr(uploaded_file, "filename", "audio.m4a") or "audio.m4a"
        audio_bytes = await uploaded_file.read()
        language = form.get("language")
    else:
        try:
            body = await request.json()
        except Exception:
            raise HTTPException(status_code=400, detail="Invalid request payload. Expected JSON or multipart/form-data.")
        audio_b64 = body.get("audio_base64")
        if not audio_b64 or not str(audio_b64).strip():
            raise HTTPException(status_code=400, detail="Missing 'audio_base64' in request body.")
        filename = body.get("filename", "audio.m4a") or "audio.m4a"
        language = body.get("language")
        try:
            audio_bytes = base64.b64decode(audio_b64)
        except Exception:
            raise HTTPException(status_code=400, detail="Invalid base64 encoding for audio.")

    return await voice_service.transcribe(
        audio_bytes=audio_bytes,
        filename=filename,
        language=language,
    )

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
