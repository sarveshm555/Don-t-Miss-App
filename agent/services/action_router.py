"""Action Router for Don't Miss.

Routes human-confirmed reminder actions to designated channels:
- "local": Android local notification (handled on device)
- "whatsapp": WhatsApp message via Twilio (handled on backend)
"""

import logging
from typing import Dict, Any, List
from agent.models.reminder_schema import ReminderDraft
from agent.services.whatsapp_service import BaseWhatsAppService, TwilioWhatsAppService

logger = logging.getLogger(__name__)

class ActionRouter:
    """Routes confirmed reminders to target channels."""

    def __init__(self, whatsapp_service: BaseWhatsAppService | None = None):
        self.whatsapp_service = whatsapp_service or TwilioWhatsAppService()

    async def route_confirmed_action(
        self,
        draft: ReminderDraft,
        user_phone_number: str | None = None,
    ) -> Dict[str, Any]:
        """Processes a human-confirmed reminder action across requested channels."""
        channels = draft.channels or ["local", "whatsapp"]
        dispatched_channels: List[str] = []
        channel_results: Dict[str, Any] = {}

        # 1. Local channel: Always marked ready for client-side Android alarm scheduling
        if "local" in channels:
            dispatched_channels.append("local")
            channel_results["local"] = {
                "status": "READY_FOR_DEVICE_SCHEDULE",
                "detail": "Action confirmed for local Android exact alarm scheduling.",
            }

        # 2. WhatsApp channel: Dispatched via Twilio if phone number is provided
        if "whatsapp" in channels:
            if user_phone_number:
                time_str = f"{draft.dueDate or 'Scheduled date'} at {draft.dueHour or 0:02d}:{draft.dueMinute or 0:02d}"
                wa_result = await self.whatsapp_service.send_reminder(
                    to_number=user_phone_number,
                    title=draft.title,
                    due_time=time_str,
                    description=draft.description,
                    priority=draft.priority,
                )
                channel_results["whatsapp"] = wa_result
                if wa_result.get("success"):
                    dispatched_channels.append("whatsapp")
            else:
                channel_results["whatsapp"] = {
                    "status": "SKIPPED",
                    "detail": "No WhatsApp recipient phone number provided.",
                }

        return {
            "success": True,
            "status": "ROUTED",
            "channels_dispatched": dispatched_channels,
            "results": channel_results,
        }
