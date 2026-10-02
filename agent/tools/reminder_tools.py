import threading
from typing import Optional, Dict, Any, List


class ProposalTracker:
    def __init__(self):
        self._lock = threading.Lock()
        self._proposal = None
        self._call_count = 0

    def record(self, proposal: Dict[str, Any]):
        with self._lock:
            self._proposal = proposal
            self._call_count += 1

    def reset(self):
        with self._lock:
            self._proposal = None
            self._call_count = 0

    def get_proposal(self) -> Optional[Dict[str, Any]]:
        with self._lock:
            return self._proposal

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

    proposal_data = {
        "status": "PROPOSED",
        "action": "create_reminder",
        "requires_confirmation": True,
        "draft": {
            "title": title,
            "description": description,
            "dueDate": due_date,
            "dueHour": due_hour,
            "dueMinute": due_minute,
            "priority": norm_priority,
            "recurrence": norm_recurrence,
            "url": url,
            "channels": norm_channels,
            "reasoning": reasoning or "Extracted via OpenAI reminder parser",
        },
    }

    proposal_tracker.record(proposal_data)
    return proposal_data