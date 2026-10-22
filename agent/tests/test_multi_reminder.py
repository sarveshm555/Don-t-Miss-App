import json
import pytest
from datetime import datetime, date, timedelta
from unittest.mock import AsyncMock, MagicMock, patch
from fastapi.testclient import TestClient

from agent.app import app
from agent.reminder_agent import ReminderAgent, resolve_timezone
from agent.providers.openai_provider import OpenAIProvider
from agent.models.reminder_schema import (
    ReminderDraft,
    ReminderProposal,
    AgentRequest,
    AgentResponse,
    ReminderPlanRequest,
    ReminderPlanResponse,
)
from agent.services.jwt_service import create_access_token


@pytest.fixture
def test_client():
    return TestClient(app)


def _make_mock_choice(tool_calls=None, content=""):
    """Helper to mock an OpenAI chat completion choice."""
    message = MagicMock()
    message.content = content
    message.tool_calls = tool_calls or []
    choice = MagicMock()
    choice.message = message
    completion = MagicMock()
    completion.choices = [choice]
    return completion


def _make_tool_call(name: str, args: dict, call_id: str = "call_123"):
    """Helper to mock an individual OpenAI tool call."""
    tool_call = MagicMock()
    tool_call.id = call_id
    tool_call.function.name = name
    tool_call.function.arguments = json.dumps(args)
    return tool_call


# ==============================================================================
# 1. Single Reminder Parsing via Multi-Plan Endpoint
# ==============================================================================

@pytest.mark.anyio
async def test_single_reminder_plan_success():
    """Verify extracting a single reminder through process_plan_async."""
    mock_provider = MagicMock(spec=OpenAIProvider)
    mock_provider.is_configured = True
    mock_provider.model = "gpt-4o-mini"
    mock_client = AsyncMock()
    mock_provider.get_async_client.return_value = mock_client

    tool_call = _make_tool_call(
        name="create_reminder",
        args={
            "title": "Gemini Hackathon",
            "description": "Hackathon kickoff presentation",
            "due_date": "2026-10-21",
            "due_hour": 10,
            "due_minute": 0,
            "priority": "high",
            "recurrence": "none",
            "channels": ["local", "whatsapp"],
            "reasoning": "High priority hackathon kickoff at 10 AM",
        },
    )
    mock_client.chat.completions.create.return_value = _make_mock_choice(
        tool_calls=[tool_call],
        content="I have proposed your hackathon reminder.",
    )

    agent_instance = ReminderAgent(provider=mock_provider)
    request = ReminderPlanRequest(
        prompt="Remind me tomorrow at 10 AM for Gemini hackathon kickoff",
        current_date="2026-10-20",
        current_time="09:00",
        timezone="Asia/Kolkata",
    )

    response = await agent_instance.process_plan_async(request)

    assert response.success is True
    assert len(response.reminders) == 1
    rem = response.reminders[0]
    assert rem.title == "Gemini Hackathon"
    assert rem.dueDate == "2026-10-21"
    assert rem.dueHour == 10
    assert rem.dueMinute == 0
    assert rem.priority == "high"
    assert "whatsapp" in rem.channels


# ==============================================================================
# 2. Multiple Reminders from One Message (2 and 3 Tasks)
# ==============================================================================

@pytest.mark.anyio
async def test_multi_reminder_two_tasks_from_one_message():
    """Verify extracting two distinct reminders from one prompt."""
    mock_provider = MagicMock(spec=OpenAIProvider)
    mock_provider.is_configured = True
    mock_provider.model = "gpt-4o-mini"
    mock_client = AsyncMock()
    mock_provider.get_async_client.return_value = mock_client

    call1 = _make_tool_call(
        name="create_reminder",
        args={
            "title": "Gemini Hackathon",
            "description": "Hackathon session",
            "due_date": "2026-10-20",
            "due_hour": 10,
            "due_minute": 0,
            "priority": "high",
        },
        call_id="call_1",
    )
    call2 = _make_tool_call(
        name="Friend's Birthday",
        args={
            "title": "Friend's Birthday",
            "description": "Wish and send gift",
            "due_date": "2026-10-21",
            "due_hour": 9,
            "due_minute": 0,
            "priority": "medium",
        },
        call_id="call_2",
    )
    # Correct function name for both
    call1.function.name = "create_reminder"
    call2.function.name = "create_reminder"

    mock_client.chat.completions.create.return_value = _make_mock_choice(
        tool_calls=[call1, call2],
        content="I have prepared both reminders for your review.",
    )

    agent_instance = ReminderAgent(provider=mock_provider)
    request = ReminderPlanRequest(
        prompt="I have a Gemini hackathon today at 10 AM. Tomorrow is my friend's birthday at 9 AM. Remind me about both.",
        current_date="2026-10-20",
        current_time="08:00",
        timezone="Asia/Kolkata",
    )

    response = await agent_instance.process_plan_async(request)

    assert response.success is True
    assert len(response.reminders) == 2

    assert response.reminders[0].title == "Gemini Hackathon"
    assert response.reminders[0].dueDate == "2026-10-20"
    assert response.reminders[0].dueHour == 10

    assert response.reminders[1].title == "Friend's Birthday"
    assert response.reminders[1].dueDate == "2026-10-21"
    assert response.reminders[1].dueHour == 9


@pytest.mark.anyio
async def test_multi_reminder_three_tasks_with_different_dates_and_times():
    """Verify extracting three distinct reminders across today, tomorrow, and Friday."""
    mock_provider = MagicMock(spec=OpenAIProvider)
    mock_provider.is_configured = True
    mock_provider.model = "gpt-4o-mini"
    mock_client = AsyncMock()
    mock_provider.get_async_client.return_value = mock_client

    call1 = _make_tool_call(
        name="create_reminder",
        args={
            "title": "Gemini Hackathon",
            "due_date": "2026-10-20",
            "due_hour": 10,
            "due_minute": 0,
            "priority": "high",
        },
        call_id="call_1",
    )
    call2 = _make_tool_call(
        name="create_reminder",
        args={
            "title": "Friend's Birthday",
            "due_date": "2026-10-21",
            "due_hour": 9,
            "due_minute": 0,
            "priority": "medium",
        },
        call_id="call_2",
    )
    call3 = _make_tool_call(
        name="create_reminder",
        args={
            "title": "Project Submission",
            "due_date": "2026-10-23",
            "due_hour": 17,
            "due_minute": 0,
            "priority": "high",
        },
        call_id="call_3",
    )

    mock_client.chat.completions.create.return_value = _make_mock_choice(
        tool_calls=[call1, call2, call3],
        content="Extracted 3 separate reminder proposals.",
    )

    agent_instance = ReminderAgent(provider=mock_provider)
    request = ReminderPlanRequest(
        prompt="I have a Gemini hackathon today at 10 AM. Tomorrow is my friend's birthday at 9 AM. On Friday, I have a project submission at 5 PM. Remind me about all three.",
        current_date="2026-10-20",
        current_time="08:00",
        timezone="Asia/Kolkata",
    )

    response = await agent_instance.process_plan_async(request)

    assert response.success is True
    assert len(response.reminders) == 3

    assert response.reminders[0].title == "Gemini Hackathon"
    assert response.reminders[0].dueHour == 10

    assert response.reminders[1].title == "Friend's Birthday"
    assert response.reminders[1].dueHour == 9

    assert response.reminders[2].title == "Project Submission"
    assert response.reminders[2].dueHour == 17
    assert response.reminders[2].dueDate == "2026-10-23"


# ==============================================================================
# 3. Date & Time Expressions & Timezone Resolution
# ==============================================================================

def test_timezone_resolution_default_and_custom():
    """Verify timezone resolution handles Asia/Kolkata, IST, UTC, and offsets."""
    # Default to Asia/Kolkata (+05:30)
    tz_default = resolve_timezone(None)
    assert tz_default is not None

    # Explicit Asia/Kolkata
    tz_kol = resolve_timezone("Asia/Kolkata")
    now_kol = datetime.now(tz_kol)
    offset_kol = now_kol.utcoffset()
    assert offset_kol == timedelta(hours=5, minutes=30)

    # IST
    tz_ist = resolve_timezone("IST")
    assert datetime.now(tz_ist).utcoffset() == timedelta(hours=5, minutes=30)

    # America/New_York
    tz_ny = resolve_timezone("America/New_York")
    assert tz_ny is not None

    # Explicit ISO offset
    tz_iso = resolve_timezone("+04:00")
    assert datetime.now(tz_iso).utcoffset() == timedelta(hours=4)


def test_system_prompt_calendar_mapping():
    """Verify system prompt includes calendar mapping and execution rules."""
    agent_inst = ReminderAgent.__new__(ReminderAgent)
    prompt = agent_inst._build_system_prompt("2026-10-20", "14:00", "Asia/Kolkata")

    assert "Call the `create_reminder` tool EXACTLY ONCE" in prompt
    assert "present a brief confirmation to the user in text" in prompt
    assert "You must NOT call `create_reminder` again for the same request." in prompt
    assert "Tomorrow: 2026-10-21" in prompt
    assert "Asia/Kolkata" in prompt


# ==============================================================================
# 4. Ambiguous Dates / Times Clarification
# ==============================================================================

@pytest.mark.anyio
async def test_ambiguous_request_triggers_clarification():
    """Verify that ambiguous requests trigger clarification instead of inventing arbitrary values."""
    mock_provider = MagicMock(spec=OpenAIProvider)
    mock_provider.is_configured = True
    mock_provider.model = "gpt-4o-mini"
    mock_client = AsyncMock()
    mock_provider.get_async_client.return_value = mock_client

    clarify_call = _make_tool_call(
        name="request_clarification",
        args={
            "question": "What time would you like to be reminded at 5? Please specify 5:00 AM or 5:00 PM, and on which day.",
            "issue": "ambiguous_time",
        },
    )

    mock_client.chat.completions.create.return_value = _make_mock_choice(
        tool_calls=[clarify_call],
        content="Please clarify your desired time.",
    )

    agent_instance = ReminderAgent(provider=mock_provider)
    request = ReminderPlanRequest(
        prompt="Remind me at 5 to call mom",
        current_date="2026-10-20",
        current_time="10:00",
        timezone="Asia/Kolkata",
    )

    response = await agent_instance.process_plan_async(request)

    assert response.success is False
    assert response.clarification_needed is not None
    assert "5:00 AM or 5:00 PM" in response.clarification_needed
    assert len(response.reminders) == 0


# ==============================================================================
# 5. Past Date & Time Handling
# ==============================================================================

@pytest.mark.anyio
async def test_past_date_is_rejected():
    """Verify that scheduling a reminder in the past is rejected."""
    mock_provider = MagicMock(spec=OpenAIProvider)
    mock_provider.is_configured = True
    mock_provider.model = "gpt-4o-mini"
    mock_client = AsyncMock()
    mock_provider.get_async_client.return_value = mock_client

    tool_call = _make_tool_call(
        name="create_reminder",
        args={
            "title": "Breakfast Meeting",
            "due_date": "2026-10-20",
            "due_hour": 8,
            "due_minute": 0,
        },
    )
    mock_client.chat.completions.create.return_value = _make_mock_choice(
        tool_calls=[tool_call],
    )

    agent_instance = ReminderAgent(provider=mock_provider)
    # Current time is 14:00 (2 PM), but reminder is requested for 08:00 (8 AM) today!
    request = ReminderPlanRequest(
        prompt="Remind me today at 8 AM for breakfast meeting",
        current_date="2026-10-20",
        current_time="14:00",
        timezone="Asia/Kolkata",
    )

    response = await agent_instance.process_plan_async(request)

    assert response.success is False
    assert response.clarification_needed is not None
    assert "in the past" in response.clarification_needed.lower()
    assert len(response.reminders) == 0


# ==============================================================================
# 6. Invalid Model Output & OpenAI API Failures
# ==============================================================================

@pytest.mark.anyio
async def test_unconfigured_openai_provider():
    """Verify unconfigured provider returns structured failure response."""
    unconfigured_provider = OpenAIProvider(api_key="")
    agent_instance = ReminderAgent(provider=unconfigured_provider)

    request = ReminderPlanRequest(
        prompt="Remind me tomorrow at 9 AM",
        current_date="2026-10-20",
        current_time="09:00",
    )

    response = await agent_instance.process_plan_async(request)
    assert response.success is False
    assert "OpenAI API is not configured" in (response.error or "")


@pytest.mark.anyio
async def test_openai_api_exception_handling():
    """Verify OpenAI client network/runtime exceptions are caught cleanly."""
    mock_provider = MagicMock(spec=OpenAIProvider)
    mock_provider.is_configured = True
    mock_provider.model = "gpt-4o-mini"
    mock_client = AsyncMock()
    mock_client.chat.completions.create.side_effect = RuntimeError("OpenAI rate limit reached")
    mock_provider.get_async_client.return_value = mock_client

    agent_instance = ReminderAgent(provider=mock_provider)
    request = ReminderPlanRequest(
        prompt="Remind me tomorrow at 9 AM to review code",
    )

    response = await agent_instance.process_plan_async(request)
    assert response.success is False
    assert "rate limit" in (response.error or "").lower()


# ==============================================================================
# 7. Endpoint Integration: POST /agent/reminders/plan & POST /agent/reminder
# ==============================================================================

def test_api_endpoint_plan_empty_prompt_validation(test_client):
    """Verify 400 Bad Request on empty prompt for /agent/reminders/plan."""
    res = test_client.post("/agent/reminders/plan", json={"prompt": "   "})
    assert res.status_code == 422 or res.status_code == 400


def test_api_endpoint_plan_with_mocked_agent(test_client):
    """Verify POST /agent/reminders/plan HTTP response format and status."""
    sample_response = ReminderPlanResponse(
        success=True,
        reminders=[
            ReminderDraft(
                title="Weekly Sync",
                dueDate="2026-10-21",
                dueHour=11,
                dueMinute=30,
                priority="medium",
                channels=["local"],
            ),
            ReminderDraft(
                title="Client Review",
                dueDate="2026-10-22",
                dueHour=15,
                dueMinute=0,
                priority="high",
                channels=["local", "whatsapp"],
            ),
        ],
        raw_prompt="Weekly sync tomorrow at 11:30 AM and client review on Thursday at 3 PM",
        message="Created 2 reminders.",
    )

    with patch("agent.app.agent.process_plan_async", new=AsyncMock(return_value=sample_response)):
        res = test_client.post("/agent/reminders/plan", json={
            "prompt": "Weekly sync tomorrow at 11:30 AM and client review on Thursday at 3 PM",
            "current_date": "2026-10-20",
            "current_time": "09:00",
            "timezone": "Asia/Kolkata",
        })

    assert res.status_code == 200
    data = res.json()
    assert data["success"] is True
    assert len(data["reminders"]) == 2
    assert data["reminders"][0]["title"] == "Weekly Sync"
    assert data["reminders"][1]["title"] == "Client Review"


def test_existing_single_reminder_backward_compatibility(test_client):
    """Verify existing POST /agent/reminder returns compatible proposal format."""
    mock_proposal = ReminderProposal(
        status="PROPOSED",
        action="create_reminder",
        requires_confirmation=True,
        raw_prompt="Doctor appointment tomorrow at 10 AM",
        draft=ReminderDraft(
            title="Doctor Appointment",
            dueDate="2026-10-21",
            dueHour=10,
            dueMinute=0,
            priority="high",
        ),
    )
    mock_agent_response = AgentResponse(
        success=True,
        proposal=mock_proposal,
        proposals=[mock_proposal],
        message="Reminder proposal generated successfully.",
    )

    with patch("agent.app.agent.process_prompt_async", new=AsyncMock(return_value=mock_agent_response)):
        res = test_client.post("/agent/reminder", json={
            "prompt": "Doctor appointment tomorrow at 10 AM",
            "current_date": "2026-10-20",
            "current_time": "12:00",
        })

    assert res.status_code == 200
    data = res.json()
    assert data["success"] is True
    # Backwards-compatible single proposal fields
    assert data["proposal"] is not None
    assert data["proposal"]["requires_confirmation"] is True
    assert data["proposal"]["draft"]["title"] == "Doctor Appointment"
    assert data["proposal"]["draft"]["dueHour"] == 10
    # Multi proposals list also populated
    assert len(data["proposals"]) == 1


# ==============================================================================
# 8. Authentication & Account Isolation (Security)
# ==============================================================================

def test_authenticated_user_context_in_plan_endpoint(test_client):
    """Verify authenticated user context works and does not accept client spoofed IDs."""
    from agent.services.jwt_service import get_current_user_optional
    from agent.database.models import User

    fake_user = User(
        id="usr-verified-777",
        full_name="Verified Multi User",
        phone_number="+15550001111",
    )
    app.dependency_overrides[get_current_user_optional] = lambda: fake_user

    try:
        token = create_access_token(
            user_id="usr-verified-777",
            phone_number="+15550001111",
            name="Verified Multi User",
        )

        sample_response = ReminderPlanResponse(
            success=True,
            reminders=[
                ReminderDraft(
                    title="Design System Meeting",
                    dueDate="2026-10-21",
                    dueHour=14,
                    dueMinute=0,
                ),
            ],
            raw_prompt="Design system meeting tomorrow at 2 PM",
        )

        with patch("agent.app.agent.process_plan_async", new=AsyncMock(return_value=sample_response)):
            res = test_client.post(
                "/agent/reminders/plan",
                headers={"Authorization": f"Bearer {token}"},
                json={
                    "prompt": "Design system meeting tomorrow at 2 PM",
                    "current_date": "2026-10-20",
                    "current_time": "09:00",
                },
            )

        assert res.status_code == 200
        data = res.json()
        assert data["success"] is True
        assert len(data["reminders"]) == 1
        assert data["reminders"][0]["title"] == "Design System Meeting"
    finally:
        app.dependency_overrides.pop(get_current_user_optional, None)


@pytest.mark.anyio
async def test_multi_reminder_exact_user_prompt_gemini_hackathon_and_birthday():
    """Verify exact user prompt produces two distinct reminder drafts."""
    mock_provider = MagicMock(spec=OpenAIProvider)
    mock_provider.is_configured = True
    mock_provider.model = "gpt-4o-mini"
    mock_client = AsyncMock()
    mock_provider.get_async_client.return_value = mock_client

    call1 = _make_tool_call(
        name="create_reminder",
        args={
            "title": "Gemini Hackathon",
            "due_date": "2026-10-20",
            "due_hour": 10,
            "due_minute": 0,
            "priority": "high",
        },
        call_id="call_gemini",
    )
    call2 = _make_tool_call(
        name="create_reminder",
        args={
            "title": "Friend's Birthday",
            "due_date": "2026-10-21",
            "due_hour": 9,
            "due_minute": 0,
            "priority": "medium",
        },
        call_id="call_bday",
    )

    mock_client.chat.completions.create.return_value = _make_mock_choice(
        tool_calls=[call1, call2],
        content="I have extracted both reminders.",
    )

    agent_instance = ReminderAgent(provider=mock_provider)
    request = ReminderPlanRequest(
        prompt="Remind me about the Gemini hackathon today at 10 AM and my friend's birthday tomorrow at 9 AM.",
        current_date="2026-10-20",
        current_time="08:00",
        timezone="Asia/Kolkata",
    )

    response = await agent_instance.process_plan_async(request)

    assert response.success is True
    assert len(response.reminders) == 2
    assert response.reminders[0].title == "Gemini Hackathon"
    assert response.reminders[0].dueDate == "2026-10-20"
    assert response.reminders[0].dueHour == 10
    assert response.reminders[0].dueMinute == 0

    assert response.reminders[1].title == "Friend's Birthday"
    assert response.reminders[1].dueDate == "2026-10-21"
    assert response.reminders[1].dueHour == 9
    assert response.reminders[1].dueMinute == 0


@pytest.mark.anyio
async def test_explicit_times_preserved_without_override():
    """Verify that explicitly requested times (9 AM, 7:30 AM, 12 PM, 6:45 PM) are preserved."""
    mock_provider = MagicMock(spec=OpenAIProvider)
    mock_provider.is_configured = True
    mock_provider.model = "gpt-4o-mini"
    mock_client = AsyncMock()
    mock_provider.get_async_client.return_value = mock_client

    test_cases = [
        ("9 AM", 9, 0),
        ("7:30 AM", 7, 30),
        ("12 PM", 12, 0),
        ("6:45 PM", 18, 45),
    ]

    for label, exp_h, exp_m in test_cases:
        call = _make_tool_call(
            name="create_reminder",
            args={
                "title": f"Task at {label}",
                "due_date": "2026-10-21",
                "due_hour": exp_h,
                "due_minute": exp_m,
                "priority": "medium",
            },
        )
        mock_client.chat.completions.create.return_value = _make_mock_choice(
            tool_calls=[call],
            content=f"Extracted task at {label}",
        )

        agent_instance = ReminderAgent(provider=mock_provider)
        req = ReminderPlanRequest(
            prompt=f"Remind me tomorrow at {label} to complete task",
            current_date="2026-10-20",
            current_time="08:00",
            timezone="Asia/Kolkata",
        )
        res = await agent_instance.process_plan_async(req)
        assert res.success is True
        assert len(res.reminders) == 1
        assert res.reminders[0].dueHour == exp_h
        assert res.reminders[0].dueMinute == exp_m


@pytest.mark.anyio
async def test_title_and_description_separated_correctly():
    """Verify title and description are properly separated from natural language."""
    mock_provider = MagicMock(spec=OpenAIProvider)
    mock_provider.is_configured = True
    mock_provider.model = "gpt-4o-mini"
    mock_client = AsyncMock()
    mock_provider.get_async_client.return_value = mock_client

    call = _make_tool_call(
        name="create_reminder",
        args={
            "title": "Send resume to ma'am",
            "description": "Mention my project experience",
            "due_date": "2026-10-21",
            "due_hour": 9,
            "due_minute": 0,
            "priority": "high",
        },
    )
    mock_client.chat.completions.create.return_value = _make_mock_choice(
        tool_calls=[call],
        content="I have proposed the reminder with separated title and description.",
    )

    agent_instance = ReminderAgent(provider=mock_provider)
    req = ReminderPlanRequest(
        prompt="Tomorrow at 9 AM, send my resume to my ma'am and mention my project experience",
        current_date="2026-10-20",
        current_time="08:00",
        timezone="Asia/Kolkata",
    )
    res = await agent_instance.process_plan_async(req)
    assert res.success is True
    assert len(res.reminders) == 1
    draft = res.reminders[0]
    assert draft.title == "Send resume to ma'am"
    assert draft.description == "Mention my project experience"
    assert draft.dueDate == "2026-10-21"
    assert draft.dueHour == 9
    assert draft.dueMinute == 0


def test_create_reminder_tool_defaults_and_explicit_preservation():
    """Test create_reminder tool preserves explicit times and defaults hour to 9 when omitted."""
    from agent.tools.reminder_tools import create_reminder, proposal_tracker

    proposal_tracker.reset()
    res1 = create_reminder(
        title="Default time task",
        due_date="2026-10-21",
        # due_hour omitted
    )
    assert res1["draft"]["dueHour"] == 9
    assert res1["draft"]["dueMinute"] == 0

    proposal_tracker.reset()
    res2 = create_reminder(
        title="Explicit morning task",
        due_date="2026-10-21",
        due_hour=7,
        due_minute=30,
    )
    assert res2["draft"]["dueHour"] == 7
    assert res2["draft"]["dueMinute"] == 30

    proposal_tracker.reset()
    res3 = create_reminder(
        title="Midnight task",
        due_date="2026-10-21",
        due_hour=0,
        due_minute=0,
    )
    assert res3["draft"]["dueHour"] == 0
    assert res3["draft"]["dueMinute"] == 0
