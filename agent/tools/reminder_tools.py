import threading
from typing import Optional, Dict, Any, List


class ProposalTracker:
    def __init__(self):
        self._lock = threading.Lock()
        self._proposals: List[Dict[str, Any]] = []
        self._clarification_question: Optional[str] = None
        self._clarification_issue: Optional[str] = None
        self._call_count = 0

    def record(self, proposal: Dict[str, Any]):
        with self._lock:
            self._proposals.append(proposal)
            self._call_count += 1

    def record_clarification(self, question: str, issue: Optional[str] = None):
        with self._lock:
            self._clarification_question = question
            self._clarification_issue = issue
            self._call_count += 1

    def reset(self):
        with self._lock:
            self._proposals = []
            self._clarification_question = None
            self._clarification_issue = None
            self._call_count = 0

    def get_proposal(self) -> Optional[Dict[str, Any]]:
        with self._lock:
            return self._proposals[0] if self._proposals else None

    def get_proposals(self) -> List[Dict[str, Any]]:
        with self._lock:
            return list(self._proposals)

    def get_clarification(self) -> Optional[str]:
        with self._lock:
            return self._clarification_question

    def get_call_count(self) -> int:
        with self._lock:
            return self._call_count


proposal_tracker = ProposalTracker()


def create_reminder(
    title: str,
    description: Optional[str] = None,
    due_date: Optional[str] = None,
    due_hour: Optional[int] = None,
    due_minute: Optional[int] = None,
    priority: str = "medium",
    recurrence: str = "none",
    url: Optional[str] = None,
    channels: Optional[List[str]] = None,
    reasoning: Optional[str] = None,
) -> Dict[str, Any]:
    """Propose a new reminder to the user.

    This function DOES NOT directly create or persist the reminder.
    It creates a structured proposal that requires explicit user
    confirmation before any reminder is saved.

    Args:
        title: The reminder title or core task name.
        description: Additional details, context, notes, or reasons.
        due_date: Due date formatted as 'YYYY-MM-DD'.
        due_hour: Hour of the due time in 24-hour format (0 to 23).
        due_minute: Minute of the due time (0 to 59).
        priority: Priority level: low, medium, or high.
        recurrence: Recurrence frequency: none, daily, weekly, or monthly.
        url: Any website URL mentioned.
        channels: Delivery channels, e.g. ['local', 'whatsapp'].
        reasoning: Brief note explaining the extracted details.

    Returns:
        A dictionary containing the structured reminder proposal.
    """

    norm_priority = priority.lower() if priority else "medium"
    if norm_priority not in ("low", "medium", "high"):
        norm_priority = "medium"

    norm_recurrence = recurrence.lower() if recurrence else "none"
    if norm_recurrence not in ("none", "daily", "weekly", "monthly"):
        norm_recurrence = "none"

    norm_channels = (
        channels
        if channels and isinstance(channels, list)
        else ["local", "whatsapp"]
    )

    effective_hour = due_hour
    effective_minute = due_minute
    if effective_hour is None and due_date:
        effective_hour = 9
        effective_minute = 0 if effective_minute is None else effective_minute

    proposal_data = {
        "status": "PROPOSED",
        "action": "create_reminder",
        "requires_confirmation": True,
        "draft": {
            "title": title,
            "description": description,
            "dueDate": due_date,
            "dueHour": effective_hour,
            "dueMinute": effective_minute,
            "priority": norm_priority,
            "recurrence": norm_recurrence,
            "url": url,
            "channels": norm_channels,
            "reasoning": reasoning or "Extracted via OpenAI reminder parser",
        },
    }

    proposal_tracker.record(proposal_data)
    return proposal_data


def request_clarification(
    question: str,
    issue: Optional[str] = None,
) -> Dict[str, Any]:
    """Request clarification from the user when details or dates/times are ambiguous or missing.

    Args:
        question: The clear, concise question to present to the user.
        issue: Categorization of the ambiguity (e.g. 'ambiguous_date_time', 'past_date_time', 'missing_details').

    Returns:
        A dictionary containing the clarification request details.
    """
    proposal_tracker.record_clarification(question=question, issue=issue)
    return {
        "status": "CLARIFICATION_REQUESTED",
        "question": question,
        "issue": issue or "ambiguous_input",
    }


CLARIFICATION_TOOL_DEFINITION = {
    "type": "function",
    "function": {
        "name": "request_clarification",
        "description": "Call this tool if the user's request has ambiguous, incomplete, or past dates/times that cannot be safely determined without user clarification.",
        "parameters": {
            "type": "object",
            "properties": {
                "question": {
                    "type": "string",
                    "description": "The clarification question to ask the user."
                },
                "issue": {
                    "type": "string",
                    "description": "The category of the ambiguity (e.g. 'ambiguous_time', 'past_date_time', 'missing_details')."
                }
            },
            "required": ["question"]
        }
    }
}

REMINDER_TOOL_DEFINITION = {
    "type": "function",
    "function": {
        "name": "create_reminder",
        "description": "Propose a structured reminder draft to the user. This tool DOES NOT directly persist the reminder; it creates a structured proposal awaiting explicit user confirmation. For requests describing multiple tasks or events, call this tool once for each distinct task.",
        "parameters": {
            "type": "object",
            "properties": {
                "title": {
                    "type": "string",
                    "description": "Concise, actionable reminder title or core task name (e.g. 'Send resume to ma\'am', 'Amazon interview', 'Doctor appointment'). Keep it short and actionable (typically 3 to 7 words). Do NOT include secondary clauses, instructions, or notes here."
                },
                "description": {
                    "type": "string",
                    "description": "Additional instructions, details, context, notes, secondary clauses, mentions, or reasons (e.g. 'Mention my project experience', 'Bring blood test report', 'Prepare interview questions')."
                },
                "due_date": {
                    "type": "string",
                    "description": "Due date formatted strictly as 'YYYY-MM-DD'."
                },
                "due_hour": {
                    "type": "integer",
                    "description": "Hour of the due time in 24-hour format (0 to 23). E.g. 9 for 9 AM, 21 for 9 PM, 7 for 7:30 AM, 12 for 12 PM. If no specific time of day is requested by the user, use 9 (09:00 AM default). NEVER change an explicitly requested time."
                },
                "due_minute": {
                    "type": "integer",
                    "description": "Minute of the due time (0 to 59). E.g. 0 for 9 AM, 30 for 7:30 AM, 45 for 6:45 PM. If no minute is specified, use 0."
                },
                "priority": {
                    "type": "string",
                    "enum": ["low", "medium", "high"],
                    "description": "Priority level, must be one of: 'low', 'medium', 'high'. Default is 'medium'."
                },
                "recurrence": {
                    "type": "string",
                    "enum": ["none", "daily", "weekly", "monthly"],
                    "description": "Recurrence frequency, must be one of: 'none', 'daily', 'weekly', 'monthly'. Default is 'none'."
                },
                "url": {
                    "type": "string",
                    "description": "Any website URL mentioned (e.g. 'https://...')."
                },
                "channels": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Delivery channels, e.g. ['local', 'whatsapp']. Default is ['local', 'whatsapp']."
                },
                "reasoning": {
                    "type": "string",
                    "description": "Brief note explaining the extracted details."
                }
            },
            "required": ["title"]
        }
    }
}
