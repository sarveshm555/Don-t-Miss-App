import os
import re
import json
import asyncio
import datetime
import logging
from typing import Optional, Dict, Any, List, Tuple
from agent.providers.openai_provider import OpenAIProvider
from agent.tools.reminder_tools import (
    create_reminder,
    request_clarification,
    proposal_tracker,
    REMINDER_TOOL_DEFINITION,
    CLARIFICATION_TOOL_DEFINITION,
)
from agent.models.reminder_schema import (
    ReminderDraft,
    ReminderProposal,
    AgentRequest,
    AgentResponse,
    ReminderPlanRequest,
    ReminderPlanResponse,
)

logger = logging.getLogger(__name__)


def resolve_timezone(tz_name: Optional[str] = None) -> datetime.tzinfo:
    """Resolve a timezone identifier with safe fallback to Asia/Kolkata."""
    name = (tz_name or "").strip()
    if not name or name.lower() in ("default", "none"):
        name = "Asia/Kolkata"

    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo(name)
    except Exception:
        pass

    normalized = name.lower()
    mapping = {
        "asia/kolkata": datetime.timezone(datetime.timedelta(hours=5, minutes=30)),
        "ist": datetime.timezone(datetime.timedelta(hours=5, minutes=30)),
        "utc": datetime.timezone.utc,
        "gmt": datetime.timezone.utc,
        "america/new_york": datetime.timezone(datetime.timedelta(hours=-5)),
        "est": datetime.timezone(datetime.timedelta(hours=-5)),
        "edt": datetime.timezone(datetime.timedelta(hours=-4)),
        "america/chicago": datetime.timezone(datetime.timedelta(hours=-6)),
        "cst": datetime.timezone(datetime.timedelta(hours=-6)),
        "cdt": datetime.timezone(datetime.timedelta(hours=-5)),
        "america/denver": datetime.timezone(datetime.timedelta(hours=-7)),
        "mst": datetime.timezone(datetime.timedelta(hours=-7)),
        "mdt": datetime.timezone(datetime.timedelta(hours=-6)),
        "america/los_angeles": datetime.timezone(datetime.timedelta(hours=-8)),
        "pst": datetime.timezone(datetime.timedelta(hours=-8)),
        "pdt": datetime.timezone(datetime.timedelta(hours=-7)),
        "europe/london": datetime.timezone(datetime.timedelta(hours=0)),
        "europe/paris": datetime.timezone(datetime.timedelta(hours=1)),
        "europe/berlin": datetime.timezone(datetime.timedelta(hours=1)),
        "asia/dubai": datetime.timezone(datetime.timedelta(hours=4)),
        "asia/singapore": datetime.timezone(datetime.timedelta(hours=8)),
        "asia/tokyo": datetime.timezone(datetime.timedelta(hours=9)),
        "australia/sydney": datetime.timezone(datetime.timedelta(hours=10)),
    }
    if normalized in mapping:
        return mapping[normalized]

    iso_match = re.match(r"^([+-])(\d{1,2}):?(\d{2})?$", name)
    if iso_match:
        sign = -1 if iso_match.group(1) == "-" else 1
        hours = int(iso_match.group(2))
        minutes = int(iso_match.group(3) or 0)
        return datetime.timezone(datetime.timedelta(hours=sign * hours, minutes=sign * minutes))

    return datetime.timezone(datetime.timedelta(hours=5, minutes=30))


class ReminderAgent:
    """Production AI Agent powered by OpenAI API.

    Replaces previous Amazon Bedrock and local Qwen/Ollama inference with OpenAI models (default: gpt-4o-mini).
    Operates strictly under a Human-in-the-Loop paradigm: proposes reminder drafts
    via create_reminder function calling without persisting or executing actions directly.
    Supports single-reminder and multi-reminder natural language requests.
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

    def _build_system_prompt(
        self,
        current_date: str,
        current_time: str,
        timezone_name: str = "Asia/Kolkata",
    ) -> str:
        try:
            ref_date = datetime.date.fromisoformat(current_date)
            day_of_week = ref_date.strftime("%A")
        except Exception:
            ref_date = datetime.date.today()
            day_of_week = ref_date.strftime("%A")

        upcoming_days = []
        for offset in range(1, 8):
            future = ref_date + datetime.timedelta(days=offset)
            upcoming_days.append(f"  * {future.strftime('%A')}: {future.strftime('%Y-%m-%d')}")
        calendar_context = "\n".join(upcoming_days)

        return f"""You are the AI Reminder Assistant for the "Don't Miss" personal action assistant app.
Your task is to extract reminder details from user requests and call the `create_reminder` tool.

CURRENT TIME CONTEXT:
- Today's date is: {current_date} ({day_of_week})
- Current local time is: {current_time}
- User configured timezone: {timezone_name} (default: Asia/Kolkata)
- Upcoming calendar references:
  * Tomorrow: {(ref_date + datetime.timedelta(days=1)).strftime('%Y-%m-%d')}
  * Day after tomorrow: {(ref_date + datetime.timedelta(days=2)).strftime('%Y-%m-%d')}
{calendar_context}

EXECUTION RULES:
1. Call the `create_reminder` tool EXACTLY ONCE with the extracted reminder details for single-task requests. For multiple distinct tasks/reminders in one message, call `create_reminder` once for EACH distinct task (e.g. 2 tasks -> 2 calls, 3 tasks -> 3 calls). You must NOT call `create_reminder` again for the same request. NEVER combine multiple distinct events or tasks into a single reminder!
   - Example: "Remind me about the Gemini hackathon today at 10 AM and my friend's birthday tomorrow at 9 AM" describes two distinct events. You must generate TWO calls:
     * Call 1: title="Gemini Hackathon", due_date={current_date}, due_hour=10, due_minute=0
     * Call 2: title="Friend's Birthday", due_date={(ref_date + datetime.timedelta(days=1)).strftime('%Y-%m-%d')}, due_hour=9, due_minute=0
2. After the `create_reminder` tool returns, present a brief confirmation to the user in text.
3. If a request has ambiguous references (e.g. 'at 5' without AM/PM or date, or 'sometime next week' without any date), or requests a reminder time that has already passed, call the `request_clarification` tool with a clear question asking the user for details. Note: If the user provides a valid date (e.g. 'tomorrow') without specifying a time of day, do NOT ask for clarification—apply the standard default time of 09:00 AM.

FIELD EXTRACTION GUIDELINES:
- Calculate relative dates using today's date ({current_date}):
  * 'tomorrow' -> exactly 1 day after {current_date} (formatted as YYYY-MM-DD)
  * 'today' -> {current_date}
  * 'day after tomorrow' -> 2 days after {current_date}
  * 'this Friday', 'next Monday', etc. -> calculate using the upcoming calendar mapping above.
  * 'in X hours' -> calculate the time X hours from {current_time} today (if it rolls past midnight, increment the date).
- TIME EXTRACTION & PRESERVATION (CRITICAL):
  * Strictly preserve any explicitly requested time (e.g. '9 AM' -> due_hour=9, due_minute=0; '7:30 AM' -> due_hour=7, due_minute=30; '12 PM' -> due_hour=12, due_minute=0; '6:45 PM' -> due_hour=18, due_minute=45; '9 PM' -> due_hour=21, due_minute=0).
  * NEVER round, shift, or replace an explicitly requested time with 10:00 AM or any other default!
  * For time periods without an exact minute:
    * 'morning' -> 09:00
    * 'afternoon' -> 14:00
    * 'evening' -> 18:00
    * 'night' -> 21:00
    * 'noon' -> 12:00
  * DEFAULT TIME: If a date is given (e.g. 'tomorrow', 'today', 'Friday') but NO specific time is mentioned, apply the standard default time of 09:00 AM (due_hour=9, due_minute=0). Apply this default ONLY when no time was specified by the user.
- TITLE AND DESCRIPTION SEPARATION (CRITICAL):
  * Title: Concise, actionable core task (typically 3 to 7 words, e.g. 'Send resume to ma\'am', 'Gemini hackathon', 'Doctor appointment'). Do NOT include secondary clauses, details, or notes in the title!
  * Description: Extract all secondary clauses, instructions, contextual notes, mentions, constraints, reasons, or details (e.g. 'Mention my project experience', 'Bring blood test report', 'Prepare interview questions') into the `description` field.
  * Example: Given 'Tomorrow at 9 AM, send my resume to my ma\'am and mention my project experience':
    - title: 'Send resume to ma\'am'
    - description: 'Mention my project experience'
    - due_date: {(ref_date + datetime.timedelta(days=1)).strftime('%Y-%m-%d')}
    - due_hour: 9, due_minute: 0
- Priority: 'high' for interviews, exams, deadlines, medical, bills, or urgent tasks; 'low' for leisure/casual; else 'medium'.
- Recurrence: 'daily', 'weekly', 'monthly', or 'none'.
- Channels: Set to ['local', 'whatsapp'] by default. If the user mentions WhatsApp specifically, ensure 'whatsapp' is included.
- Extract URLs if present.
- NEVER schedule a reminder in the past relative to {current_date} {current_time}. If the user asks for a past time, call `request_clarification`.
"""

    def _is_in_past(
        self,
        due_date_str: Optional[str],
        due_hour: Optional[int],
        due_minute: Optional[int],
        cur_date_str: str,
        cur_time_str: str,
    ) -> bool:
        """Check if a parsed due date/time is strictly in the past relative to the reference time."""
        if not due_date_str:
            return False
        try:
            due_d = datetime.date.fromisoformat(due_date_str)
            cur_d = datetime.date.fromisoformat(cur_date_str)
            if due_d < cur_d:
                return True
            if due_d == cur_d and due_hour is not None:
                cur_parts = cur_time_str.split(":")
                cur_h = int(cur_parts[0])
                cur_m = int(cur_parts[1]) if len(cur_parts) > 1 else 0
                d_h = due_hour
                d_m = due_minute or 0
                if (d_h < cur_h) or (d_h == cur_h and d_m < cur_m):
                    return True
        except Exception:
            pass
        return False

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
            due_hour = int(time_match.group(1)) if time_match else (9 if due_date else None)
            due_minute = int(time_match.group(2)) if time_match else (0 if due_date else None)
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
        timezone: Optional[str] = "Asia/Kolkata",
    ) -> AgentResponse:
        tz = resolve_timezone(timezone)
        now = datetime.datetime.now(tz)
        cur_d = current_date or now.strftime("%Y-%m-%d")
        cur_t = current_time or now.strftime("%H:%M")
        tz_name = timezone or "Asia/Kolkata"

        system_prompt = self._build_system_prompt(cur_d, cur_t, tz_name)
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
                tools=[REMINDER_TOOL_DEFINITION, CLARIFICATION_TOOL_DEFINITION],
                tool_choice="auto",
                temperature=0.1,
            )

            response_message = completion.choices[0].message
            content = response_message.content or ""

            # Check for tool calls (supports multiple calls in one response)
            if response_message.tool_calls:
                for tool_call in response_message.tool_calls:
                    func_name = tool_call.function.name
                    raw_args = tool_call.function.arguments
                    args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
                    if func_name == "create_reminder":
                        create_reminder(**args)
                    elif func_name == "request_clarification":
                        request_clarification(**args)

            clarification = proposal_tracker.get_clarification()
            proposals_data = proposal_tracker.get_proposals()

            # Handle clarification request when no reminders could be created
            if clarification and not proposals_data:
                return AgentResponse(
                    success=False,
                    clarification_needed=clarification,
                    message=content or clarification,
                )

            # Handle successfully extracted proposals
            if proposals_data:
                proposals = []
                for p_data in proposals_data:
                    draft_data = p_data.get("draft", {})
                    draft = ReminderDraft(**draft_data)

                    # Validation: check for past dates/times
                    if self._is_in_past(draft.dueDate, draft.dueHour, draft.dueMinute, cur_d, cur_t):
                        past_msg = (
                            f"The requested time for '{draft.title}' ({draft.dueDate} "
                            f"{draft.dueHour:02d}:{(draft.dueMinute or 0):02d}) is in the past. "
                            f"Please specify a future date and time."
                        )
                        return AgentResponse(
                            success=False,
                            clarification_needed=past_msg,
                            error=past_msg,
                            message=past_msg,
                        )

                    proposal = ReminderProposal(
                        status="PROPOSED",
                        action="create_reminder",
                        requires_confirmation=True,
                        raw_prompt=prompt,
                        draft=draft,
                    )
                    proposals.append(proposal)

                return AgentResponse(
                    success=True,
                    proposal=proposals[0],
                    proposals=proposals,
                    message=content or f"Generated {len(proposals)} reminder proposal(s).",
                )

            # Secondary fallback: model returned formatted text
            fallback = self._extract_fallback_proposal(content, prompt)
            if fallback:
                return AgentResponse(
                    success=True,
                    proposal=fallback,
                    proposals=[fallback],
                    message=content,
                )

            # Check if text response itself asks a question
            if "?" in content:
                return AgentResponse(
                    success=False,
                    clarification_needed=content.strip(),
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

    async def process_plan_async(
        self,
        request: ReminderPlanRequest,
    ) -> ReminderPlanResponse:
        """Parse natural language prompt into a multi-reminder plan."""
        agent_res = await self.process_prompt_async(
            prompt=request.prompt,
            current_date=request.current_date,
            current_time=request.current_time,
            timezone=request.timezone,
        )

        if not agent_res.success:
            return ReminderPlanResponse(
                success=False,
                reminders=[],
                raw_prompt=request.prompt,
                clarification_needed=agent_res.clarification_needed,
                message=agent_res.message,
                error=agent_res.error,
            )

        reminders = [p.draft for p in agent_res.proposals]
        return ReminderPlanResponse(
            success=True,
            reminders=reminders,
            raw_prompt=request.prompt,
            message=agent_res.message,
        )

    def process_prompt(
        self,
        prompt: str,
        current_date: Optional[str] = None,
        current_time: Optional[str] = None,
        timezone: Optional[str] = "Asia/Kolkata",
    ) -> AgentResponse:
        return asyncio.run(self.process_prompt_async(prompt, current_date, current_time, timezone))
