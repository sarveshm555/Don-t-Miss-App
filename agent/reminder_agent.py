import os
import re
import json
import asyncio
import datetime
import logging
from typing import Optional, Dict, Any
from agent.providers.openai_provider import OpenAIProvider
from agent.tools.reminder_tools import create_reminder, proposal_tracker
from agent.models.reminder_schema import ReminderDraft, ReminderProposal, AgentRequest, AgentResponse

logger = logging.getLogger(__name__)

REMINDER_TOOL_DEFINITION = {
    "type": "function",
    "function": {
        "name": "create_reminder",
        "description": "Propose a new structured reminder to the user. This tool DOES NOT directly create or persist the reminder. It creates a structured proposal that requires explicit user confirmation.",
        "parameters": {
            "type": "object",
            "properties": {
                "title": {
                    "type": "string",
                    "description": "The reminder title or core task name (e.g. 'Amazon interview', 'Dentist appointment')."
                },
                "description": {
                    "type": "string",
                    "description": "Additional details, context, notes, or reasons."
                },
                "due_date": {
                    "type": "string",
                    "description": "Due date formatted strictly as 'YYYY-MM-DD'."
                },
                "due_hour": {
                    "type": "integer",
                    "description": "Hour of the due time in 24-hour format (0 to 23). E.g. 21 for 9 PM, 9 for 9 AM."
                },
                "due_minute": {
                    "type": "integer",
                    "description": "Minute of the due time (0 to 59)."
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

class ReminderAgent:
    """Production AI Agent powered by OpenAI API.

    Replaces previous Amazon Bedrock and local Qwen/Ollama inference with OpenAI models (default: gpt-4o-mini).
    Operates strictly under a Human-in-the-Loop paradigm: proposes reminder drafts
    via create_reminder function calling without persisting or executing actions directly.
    """

    def __init__(
        self,
        provider: Optional[OpenAIProvider] = None,
        model: Optional[str] = None,
        api_key: Optional[str] = None,
    ):
        self.provider = provider or OpenAIProvider(api_key=api_key, model=model)

    @property
    def model_id(self) -> str:
        return self.provider.model

    @property
    def is_configured(self) -> bool:
        return self.provider.is_configured

    def _build_system_prompt(self, current_date: str, current_time: str) -> str:
        return f"""You are the AI Reminder Assistant for the "Don't Miss" personal action assistant app.
Your task is to extract reminder details from user requests and call the `create_reminder` tool.

CURRENT TIME CONTEXT:
- Today's date is: {current_date}
- Current local time is: {current_time}

EXECUTION RULES:
1. Call the `create_reminder` tool EXACTLY ONCE with the extracted reminder details.
2. After the `create_reminder` tool returns, present a brief confirmation to the user in text.
3. You must NOT call `create_reminder` again for the same request.

FIELD EXTRACTION GUIDELINES:
- Calculate relative dates using today's date ({current_date}):
  * 'tomorrow' -> exactly 1 day after {current_date} (formatted as YYYY-MM-DD)
  * 'today' -> {current_date}
  * 'day after tomorrow' -> 2 days after {current_date}
- Convert times to 24-hour integer due_hour (0-23) and due_minute (0-59). E.g. '9 AM' -> due_hour=9, due_minute=0. E.g. '9 PM' -> due_hour=21, due_minute=0.
- Priority: 'high' for interviews, exams, deadlines, medical, bills, or urgent tasks; 'low' for leisure/casual; else 'medium'.
- Recurrence: 'daily', 'weekly', 'monthly', or 'none'.
- Channels: Set to ['local', 'whatsapp'] by default. If the user mentions WhatsApp specifically, ensure 'whatsapp' is included.
- Extract URLs if present.
- Title: concise core task (e.g. 'Submit assignment', 'Amazon interview'). Description: reasons/details (e.g. 'prepare interview questions').
"""

    def _extract_fallback_proposal(self, text: str, raw_prompt: str) -> Optional[ReminderProposal]:
        title_match = re.search(r"\*\*Title:\*\*\s*(.+)", text, re.IGNORECASE) or re.search(r"Title:\s*(.+)", text, re.IGNORECASE)
        date_match = re.search(r"\*\*Due Date:\*\*\s*(\d{4}-\d{2}-\d{2})", text, re.IGNORECASE) or re.search(r"Due Date:\s*(\d{4}-\d{2}-\d{2})", text, re.IGNORECASE)
        time_match = re.search(r"\*\*Due Time:\*\*\s*(\d{1,2}):(\d{2})", text, re.IGNORECASE) or re.search(r"Due Time:\s*(\d{1,2}):(\d{2})", text, re.IGNORECASE)
        desc_match = re.search(r"\*\*Description:\*\*\s*(.+)", text, re.IGNORECASE) or re.search(r"Description:\s*(.+)", text, re.IGNORECASE)
        prio_match = re.search(r"\*\*Priority:\*\*\s*(low|medium|high)", text, re.IGNORECASE) or re.search(r"Priority:\s*(low|medium|high)", text, re.IGNORECASE)
        recur_match = re.search(r"\*\*Recurrence:\*\*\s*(none|daily|weekly|monthly)", text, re.IGNORECASE) or re.search(r"Recurrence:\s*(none|daily|weekly|monthly)", text, re.IGNORECASE)

        if title_match:
            title = title_match.group(1).strip().replace("*", "")
            due_date = date_match.group(1).strip() if date_match else None
            due_hour = int(time_match.group(1)) if time_match else None
            due_minute = int(time_match.group(2)) if time_match else None
            description = desc_match.group(1).strip().replace("*", "") if desc_match else None
            priority = prio_match.group(1).lower().strip() if prio_match else "medium"
            recurrence = recur_match.group(1).lower().strip() if recur_match else "none"

            draft = ReminderDraft(
                title=title,
                description=description,
                dueDate=due_date,
                dueHour=due_hour,
                dueMinute=due_minute,
                priority=priority,
                recurrence=recurrence,
                channels=["local", "whatsapp"],
                reasoning="Extracted from assistant text response (fallback)",
            )
            return ReminderProposal(
                status="PROPOSED",
                action="create_reminder",
                requires_confirmation=True,
                raw_prompt=raw_prompt,
                draft=draft,
            )
        return None

    async def process_prompt_async(
        self,
        prompt: str,
        current_date: Optional[str] = None,
        current_time: Optional[str] = None,
    ) -> AgentResponse:
        now = datetime.datetime.now()
        cur_d = current_date or now.strftime("%Y-%m-%d")
        cur_t = current_time or now.strftime("%H:%M")

        system_prompt = self._build_system_prompt(cur_d, cur_t)
        proposal_tracker.reset()

        if not self.is_configured:
            logger.warning("OpenAI API key not configured")
            return AgentResponse(
                success=False,
                error=(
                    "OpenAI API is not configured: OPENAI_API_KEY environment variable is missing. "
                    "Please configure OPENAI_API_KEY in your environment or Render dashboard."
                ),
            )

        try:
            client = self.provider.get_async_client()
            completion = await client.chat.completions.create(
                model=self.provider.model,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": prompt},
                ],
                tools=[REMINDER_TOOL_DEFINITION],
                tool_choice="auto",
                temperature=0.1,
            )

            response_message = completion.choices[0].message
            content = response_message.content or ""

            # Check for tool call
            if response_message.tool_calls:
                for tool_call in response_message.tool_calls:
                    if tool_call.function.name == "create_reminder":
                        raw_args = tool_call.function.arguments
                        args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
                        create_reminder(**args)
                        break

            proposal_data = proposal_tracker.get_proposal()
            if proposal_data:
                draft_data = proposal_data.get("draft", {})
                draft = ReminderDraft(**draft_data)
                proposal = ReminderProposal(
                    status="PROPOSED",
                    action="create_reminder",
                    requires_confirmation=True,
                    raw_prompt=prompt,
                    draft=draft,
                )
                return AgentResponse(
                    success=True,
                    proposal=proposal,
                    message=content or "Reminder proposal generated successfully.",
                )

            # Secondary fallback: model returned formatted text
            fallback = self._extract_fallback_proposal(content, prompt)
            if fallback:
                return AgentResponse(
                    success=True,
                    proposal=fallback,
                    message=content,
                )

            return AgentResponse(
                success=False,
                message=content,
                error="Agent did not propose a reminder for this prompt.",
            )

        except Exception as e:
            logger.error("Error executing OpenAI agent: %s", e)
            return AgentResponse(
                success=False,
                error=f"Error executing OpenAI agent: {str(e)}",
            )

    def process_prompt(
        self,
        prompt: str,
        current_date: Optional[str] = None,
        current_time: Optional[str] = None,
    ) -> AgentResponse:
        return asyncio.run(self.process_prompt_async(prompt, current_date, current_time))
