"""Twilio WhatsApp messaging service for Don't Miss.

Handles sending outbound WhatsApp messages using Twilio REST API.
Credentials are read strictly from environment variables:
- TWILIO_ACCOUNT_SID
- TWILIO_AUTH_TOKEN
- TWILIO_WHATSAPP_FROM (or fallback to TWILIO_WHATSAPP_NUMBER)
"""

import os
import logging
from typing import Optional, Dict, Any

logger = logging.getLogger(__name__)

_UNSET = object()


class TwilioWhatsAppService:
    """Isolated Twilio WhatsApp service client."""

    def __init__(
        self,
        account_sid: Any = _UNSET,
        auth_token: Any = _UNSET,
        from_number: Any = _UNSET,
        content_sid: Any = _UNSET,
        client: Optional[Any] = None,
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
        if content_sid is _UNSET:
            self.content_sid = os.environ.get("TWILIO_WHATSAPP_CONTENT_SID")
        else:
            self.content_sid = content_sid
        self._custom_client = client

    @property
    def is_configured(self) -> bool:
        """Checks if Twilio credentials and sender number are configured."""
        return bool(self.account_sid and self.auth_token and self.from_number)

    def _get_twilio_client(self):
        """Initializes or returns Twilio client. Avoids logging credentials."""
        if self._custom_client is not None:
            return self._custom_client
        if not self.is_configured:
            return None
        try:
            from twilio.rest import Client
            return Client(self.account_sid, self.auth_token)
        except Exception as e:
            logger.error("Failed to initialize Twilio client: %s", type(e).__name__)
            return None

    @staticmethod
    def format_whatsapp_number(number: str) -> str:
        """Normalizes a phone number to Twilio's 'whatsapp:+E164' format."""
        clean = number.strip()
        if clean.startswith("whatsapp:"):
            clean = clean[len("whatsapp:"):].strip()
        if not clean.startswith("+"):
            clean = f"+{clean}"
        return f"whatsapp:{clean}"

    def send_message(
        self,
        to_number: str,
        body: Optional[str] = None,
        content_sid: Optional[str] = None,
        content_variables: Optional[Dict[str, str]] = None,
    ) -> Dict[str, Any]:
        """Sends an outbound WhatsApp message using either Content Template or text body.
        
        Args:
            to_number: Destination phone number (with or without 'whatsapp:' prefix).
            body: Text content of the message (used when content_sid is not provided).
            content_sid: Optional Twilio Content Template SID (e.g. 'HX...').
            content_variables: Optional dictionary of variables for the template (e.g. {'1': 'title', '2': 'time'}).
            
        Returns:
            Dict containing success flag, status, and message SID or error summary.
        """
        import json

        if not to_number or not to_number.strip():
            return {
                "success": False,
                "status": "INVALID_ARGUMENT",
                "error": "Destination phone number cannot be empty.",
            }

        effective_content_sid = content_sid or self.content_sid
        if not effective_content_sid and (not body or not body.strip()):
            return {
                "success": False,
                "status": "INVALID_ARGUMENT",
                "error": "Message body or ContentSid must be provided.",
            }

        if not self.is_configured:
            logger.warning(
                "Twilio WhatsApp dispatch skipped: missing environment credentials. "
                "Set TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, and TWILIO_WHATSAPP_FROM."
            )
            return {
                "success": False,
                "status": "NOT_CONFIGURED",
                "error": "Twilio WhatsApp credentials not configured.",
            }

        client = self._get_twilio_client()
        if not client:
            return {
                "success": False,
                "status": "CLIENT_INIT_FAILED",
                "error": "Could not create Twilio client.",
            }

        formatted_to = self.format_whatsapp_number(to_number)
        formatted_from = self.format_whatsapp_number(self.from_number)

        try:
            kwargs = {
                "to": formatted_to,
                "from_": formatted_from,
            }
            if effective_content_sid:
                kwargs["content_sid"] = effective_content_sid
                if content_variables:
                    kwargs["content_variables"] = (
                        json.dumps(content_variables)
                        if isinstance(content_variables, dict)
                        else str(content_variables)
                    )
            else:
                kwargs["body"] = body

            message = client.messages.create(**kwargs)
            logger.info("Twilio WhatsApp message sent successfully. SID: %s", message.sid)
            return {
                "success": True,
                "status": "SENT",
                "sid": message.sid,
            }
        except Exception as e:
            # Safely log error without printing credentials
            logger.error("Twilio API dispatch failed: %s: %s", type(e).__name__, str(e))
            return {
                "success": False,
                "status": "FAILED",
                "error": f"Twilio API error: {type(e).__name__}",
                "detail": str(e),
            }

    def send_reminder_sync(
        self,
        to_number: str,
        title: str,
        due_time: str,
        description: Optional[str] = None,
        priority: Optional[str] = None,
        content_sid: Optional[str] = None,
        content_variables: Optional[Dict[str, str]] = None,
    ) -> Dict[str, Any]:
        """Synchronous method for sending structured reminders."""
        body = f"🔔 *Don't Miss Reminder*\n\n📌 *{title}*\n⏰ Due: {due_time}"
        if priority and priority.lower() == "high":
            body += "\n⚠️ Priority: High"
        if description:
            body += f"\n📝 Note: {description}"

        variables = content_variables or {"1": title, "2": due_time}
        return self.send_message(
            to_number=to_number,
            body=body,
            content_sid=content_sid or self.content_sid,
            content_variables=variables,
        )

    async def send_reminder(
        self,
        to_number: str,
        title: str,
        due_time: str,
        description: Optional[str] = None,
        priority: Optional[str] = None,
        content_sid: Optional[str] = None,
        content_variables: Optional[Dict[str, str]] = None,
    ) -> Dict[str, Any]:
        """Async convenience method for sending structured reminders."""
        return self.send_reminder_sync(
            to_number=to_number,
            title=title,
            due_time=due_time,
            description=description,
            priority=priority,
            content_sid=content_sid,
            content_variables=content_variables,
        )
