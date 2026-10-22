from typing import Optional, Literal, List
from pydantic import BaseModel, Field

class ReminderDraft(BaseModel):
    id: Optional[str] = Field(None, description="Optional client-generated ID for consistent local/cloud tracking")
    title: str = Field(..., description="Short, descriptive title for the reminder")
    description: Optional[str] = Field(None, description="Optional extra details or context")
    dueDate: Optional[str] = Field(None, description="Due date in ISO format YYYY-MM-DD")
    dueHour: Optional[int] = Field(None, description="Due hour in 24-hour format (0-23)")
    dueMinute: Optional[int] = Field(None, description="Due minute (0-59)")
    priority: Literal["low", "medium", "high"] = Field("medium", description="Priority level: low, medium, or high")
    recurrence: Literal["none", "daily", "weekly", "monthly"] = Field("none", description="Recurrence rule: none, daily, weekly, or monthly")
    url: Optional[str] = Field(None, description="Optional associated web link / URL")
    channels: List[str] = Field(default_factory=lambda: ["local", "whatsapp"], description="Target delivery channels: local, whatsapp")
    reasoning: Optional[str] = Field(None, description="Brief explanation of how the AI extracted these fields")

class ReminderProposal(BaseModel):
    status: Literal["PROPOSED"] = "PROPOSED"
    action: Literal["create_reminder"] = "create_reminder"
    requires_confirmation: Literal[True] = True
    raw_prompt: str = Field(..., description="The original raw natural language input")
    draft: ReminderDraft = Field(..., description="The parsed reminder draft")

class AgentRequest(BaseModel):
    prompt: str = Field(..., description="Natural language reminder request from user")
    current_date: Optional[str] = Field(None, description="Current local date in YYYY-MM-DD for relative time resolution")
    current_time: Optional[str] = Field(None, description="Current local time in HH:MM")
    timezone: Optional[str] = Field("Asia/Kolkata", description="User configured timezone, default Asia/Kolkata")

class AgentResponse(BaseModel):
    success: bool
    proposal: Optional[ReminderProposal] = None
    proposals: List[ReminderProposal] = Field(default_factory=list, description="All parsed reminder proposals")
    message: Optional[str] = None
    error: Optional[str] = None
    clarification_needed: Optional[str] = Field(None, description="Question asked if prompt is ambiguous or details are missing")

class ReminderPlanRequest(BaseModel):
    prompt: str = Field(..., min_length=1, description="Natural language prompt with one or more reminder requests")
    current_date: Optional[str] = Field(None, description="Current local date in YYYY-MM-DD")
    current_time: Optional[str] = Field(None, description="Current local time in HH:MM")
    timezone: Optional[str] = Field("Asia/Kolkata", description="User configured timezone, default Asia/Kolkata")

class ReminderPlanResponse(BaseModel):
    success: bool
    reminders: List[ReminderDraft] = Field(default_factory=list, description="Extracted independent reminder drafts")
    raw_prompt: str = Field(..., description="Original user prompt")
    clarification_needed: Optional[str] = Field(None, description="Clarification question if date/time or details are ambiguous")
    message: Optional[str] = None
    error: Optional[str] = None

class ActionConfirmRequest(BaseModel):
    action: Literal["confirm_reminder"] = "confirm_reminder"
    draft: ReminderDraft
    user_phone_number: Optional[str] = Field(None, description="Optional user WhatsApp number for external notification")
    user_id: Optional[str] = Field(None, description="Optional authenticated user ID for database persistence")
    reminder_id: Optional[str] = Field(None, description="Optional client reminder ID for consistent local and cloud identity")

class ActionConfirmResponse(BaseModel):
    success: bool
    status: str
    channels_dispatched: List[str] = Field(default_factory=list)
    message: str
    reminder_id: Optional[str] = None

class ReminderCreateRequest(BaseModel):
    id: Optional[str] = Field(None, description="Client-generated unique ID for offline-first sync")
    title: str = Field(..., min_length=1, max_length=255, description="Title of the reminder")
    description: Optional[str] = Field(None, description="Optional description or details")
    due_date: Optional[str] = Field(None, description="Due date in YYYY-MM-DD format")
    due_hour: Optional[int] = Field(None, ge=0, le=23, description="Due hour (0-23)")
    due_minute: Optional[int] = Field(None, ge=0, le=59, description="Due minute (0-59)")
    priority: Optional[Literal["low", "medium", "high"]] = Field("medium", description="Priority level")
    recurrence: Optional[Literal["none", "daily", "weekly", "monthly"]] = Field("none", description="Recurrence rule")
    url: Optional[str] = Field(None, max_length=1024, description="Associated URL")
    status: Optional[str] = Field("CONFIRMED", description="Reminder status")
    completed_at: Optional[str] = Field(None, description="Completion ISO timestamp")
    raw_prompt: Optional[str] = Field(None, description="Original user prompt")
    channels: Optional[List[str]] = Field(default_factory=lambda: ["local", "whatsapp"], description="Delivery channels")

class ReminderUpdateRequest(BaseModel):
    title: Optional[str] = Field(None, min_length=1, max_length=255)
    description: Optional[str] = None
    due_date: Optional[str] = None
    due_hour: Optional[int] = Field(None, ge=0, le=23)
    due_minute: Optional[int] = Field(None, ge=0, le=59)
    priority: Optional[Literal["low", "medium", "high"]] = None
    recurrence: Optional[Literal["none", "daily", "weekly", "monthly"]] = None
    url: Optional[str] = None
    status: Optional[str] = None
    completed_at: Optional[str] = None
    raw_prompt: Optional[str] = None
    channels: Optional[List[str]] = None

class ReminderResponse(BaseModel):
    id: str
    user_id: str
    title: str
    description: Optional[str] = None
    due_date: Optional[str] = None
    due_hour: Optional[int] = None
    due_minute: Optional[int] = None
    priority: str
    recurrence: str
    url: Optional[str] = None
    status: str
    completed_at: Optional[str] = None
    raw_prompt: Optional[str] = None
    channels: List[str] = Field(default_factory=lambda: ["local"])
    created_at: str
    updated_at: str

class ReminderSchedulingStatus(BaseModel):
    reminder_id: str = Field(..., description="ID of the associated reminder")
    channel: str = Field(..., description="Delivery channel ('local' or 'whatsapp')")
    status: str = Field(..., description="Status ('READY_FOR_DEVICE_SCHEDULE', 'SCHEDULED', 'DISPATCHED', 'SKIPPED', 'SKIPPED_UNVERIFIED', 'FAILED')")
    delivered: bool = Field(False, description="True if delivery was completed and confirmed right now")
    detail: Optional[str] = Field(None, description="Detailed status or failure message")

class BatchFailureItem(BaseModel):
    reminder_id: Optional[str] = Field(None, description="Associated reminder ID if available")
    title: Optional[str] = Field(None, description="Title of the reminder that experienced an issue")
    reason: str = Field(..., description="Human-readable reason for the failure or warning")
    action_required: Optional[str] = Field(None, description="User action required to resolve this issue")

class ReminderBatchRequest(BaseModel):
    reminders: List[ReminderDraft] = Field(..., description="List of validated reminder drafts explicitly approved by the user")
    idempotency_key: Optional[str] = Field(None, description="Client-supplied key to prevent duplicate creation on retry")

class ReminderBatchResponse(BaseModel):
    success: bool = Field(..., description="Overall success status of the batch creation")
    status: str = Field(..., description="Batch lifecycle status ('CONFIRMED', 'ALREADY_PROCESSED', 'FAILED')")
    total_requested: int = Field(..., description="Total number of reminders requested in the batch")
    total_created: int = Field(..., description="Total number of reminders persisted in this run")
    created_reminder_ids: List[str] = Field(default_factory=list, description="IDs of all created/persisted reminders")
    reminders: List[ReminderResponse] = Field(default_factory=list, description="Full persisted reminder objects")
    scheduling_status: List[ReminderSchedulingStatus] = Field(default_factory=list, description="Per-channel scheduling outcomes")
    failures: List[BatchFailureItem] = Field(default_factory=list, description="Non-fatal warnings or issues requiring user attention")
    idempotency_key: Optional[str] = Field(None, description="Echoed idempotency key")
    message: str = Field(..., description="Summary status message")

class VoiceTranscribeRequest(BaseModel):
    audio_base64: str = Field(..., description="Base64 encoded audio bytes")
    filename: Optional[str] = Field("audio.m4a", description="Original filename with extension (e.g. audio.m4a, voice.mp3)")
    language: Optional[str] = Field(None, description="Optional ISO-639-1 language code hint (e.g. 'en')")

class VoiceTranscribeResponse(BaseModel):
    success: bool = Field(..., description="Whether transcription succeeded")
    text: str = Field("", description="Transcribed natural language text")
    language: Optional[str] = Field(None, description="Detected or specified language")
    duration_seconds: Optional[float] = Field(None, description="Duration in seconds if available")
    filename: Optional[str] = Field(None, description="Filename of processed audio")
    message: Optional[str] = Field(None, description="Status or guidance message")
    error: Optional[str] = Field(None, description="Error detail if transcription failed")
