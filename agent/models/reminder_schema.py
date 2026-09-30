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

class ActionConfirmResponse(BaseModel):
    success: bool
    status: str
    channels_dispatched: List[str] = Field(default_factory=list)
    message: str
