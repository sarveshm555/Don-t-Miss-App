"""WhatsApp notification service for Don't Miss.

Provides a clean interface and Twilio implementation for WhatsApp messaging.
Credentials are read strictly from environment variables:
- TWILIO_ACCOUNT_SID
- TWILIO_AUTH_TOKEN
- TWILIO_WHATSAPP_NUMBER (e.g., "whatsapp:+14155238886")
"""

import os
import logging
from abc import ABC, abstractmethod
from typing import Optional, Dict, Any

logger = logging.getLogger(__name__)

class BaseWhatsAppService(ABC):
    """Abstract contract for WhatsApp message dispatch."""

    @property
    @abstractmethod
    def is_configured(self) -> bool:
        """Indicates whether provider credentials and sender are configured."""
        pass

    @abstractmethod
    async def send_reminder(
        self,
        to_number: str,
        title: str,
        due_time: str,
        description: Optional[str] = None,
        priority: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Dispatches a reminder message to a verified WhatsApp recipient."""
        pass


_UNSET = object()


class TwilioWhatsAppService(BaseWhatsAppService):
    """Twilio WhatsApp API provider."""

    def __init__(
        self,
        account_sid: Any = _UNSET,
        auth_token: Any = _UNSET,
        from_number: Any = _UNSET,
    ):
        self.account_sid = os.environ.get("TWILIO_ACCOUNT_SID") if account_sid is _UNSET else account_sid
        self.auth_token = os.environ.get("TWILIO_AUTH_TOKEN") if auth_token is _UNSET else auth_token
        if from_number is _UNSET:
            self.from_number = (
                os.environ.get("TWILIO_WHATSAPP_FROM")
                or os.environ.get("TWILIO_WHATSAPP_NUMBER")
            )
        else:
            self.from_number = from_number

    @property
    def is_configured(self) -> bool:
        return bool(self.account_sid and self.auth_token and self.from_number)

    async def send_reminder(
        self,
        to_number: str,
        title: str,
        due_time: str,
        description: Optional[str] = None,
        priority: Optional[str] = None,
    ) -> Dict[str, Any]:
        if not self.is_configured:
            logger.info(
                "WhatsApp dispatch skipped: Twilio credentials not configured. "
                "Set TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, and TWILIO_WHATSAPP_NUMBER to enable."
            )
            return {
                "success": False,
                "status": "NOT_CONFIGURED",
                "channel": "whatsapp",
                "detail": "Twilio WhatsApp credentials not configured in environment.",
            }

        # Format WhatsApp recipient
        formatted_recipient = to_number if to_number.startswith("whatsapp:") else f"whatsapp:{to_number}"
        formatted_sender = self.from_number if self.from_number.startswith("whatsapp:") else f"whatsapp:{self.from_number}"

        body_text = f"🔔 *Don't Miss Reminder*\n\n📌 *{title}*\n⏰ Due: {due_time}"
        if priority and priority.lower() == "high":
            body_text += "\n⚠️ Priority: High"
        if description:
            body_text += f"\n📝 Note: {description}"

        # Real dispatch using standard library or requests/httpx if configured
        try:
            import httpx
            async with httpx.AsyncClient() as client:
                url = f"https://api.twilio.com/2010-04-01/Accounts/{self.account_sid}/Messages.json"
                response = await client.post(
                    url,
                    data={
                        "From": formatted_sender,
                        "To": formatted_recipient,
                        "Body": body_text,
                    },
                    auth=(self.account_sid, self.auth_token),
                )
                if response.status_code in (200, 201):
                    data = response.json()
                    return {
                        "success": True,
                        "status": "SENT",
                        "channel": "whatsapp",
                        "message_sid": data.get("sid"),
                    }
                else:
                    return {
                        "success": False,
                        "status": "FAILED",
                        "channel": "whatsapp",
                        "status_code": response.status_code,
                        "detail": response.text,
                    }
        except Exception as e:
            logger.error("Error dispatching WhatsApp reminder via Twilio: %s", e)
            return {
                "success": False,
                "status": "ERROR",
                "channel": "whatsapp",
                "detail": str(e),
            }
