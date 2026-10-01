from typing import Optional, Literal, List
from pydantic import BaseModel, Field

class ReminderDraft(BaseModel):
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

class AgentResponse(BaseModel):
    success: bool
    proposal: Optional[ReminderProposal] = None
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
    raw_prompt: Optional[str] = None
    channels: List[str] = Field(default_factory=lambda: ["local"])
    created_at: str
    updated_at: str
