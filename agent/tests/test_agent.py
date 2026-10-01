from datetime import date
import pytest
from fastapi.testclient import TestClient
from agent.models.reminder_schema import ReminderDraft, ReminderProposal, AgentRequest, AgentResponse
from agent.tools.reminder_tools import create_reminder, proposal_tracker
from agent.reminder_agent import ReminderAgent
from agent.providers.openai_provider import OpenAIProvider
from agent.services.whatsapp_service import BaseWhatsAppService, TwilioWhatsAppService
from agent.services.action_router import ActionRouter
from agent.services.password_service import hash_password, verify_password
from agent.database.connection import get_database_url, init_db, get_db_engine, get_db_session
from agent.database.models import User, Reminder, ReminderChannel, ActionHistory
from agent.app import app, parse_due_date

def test_reminder_draft_schema_valid():
    draft = ReminderDraft(
        title="Amazon Interview",
        description="Prepare system design questions",
        dueDate="2026-09-21",
        dueHour=21,
        dueMinute=0,
        priority="high",
        recurrence="none",
        url="https://amazon.jobs",
        channels=["local", "whatsapp"],
        reasoning="Extracted Amazon interview reminder with high priority at 9 PM.",
    )
    assert draft.title == "Amazon Interview"
    assert draft.priority == "high"
    assert draft.dueHour == 21
    assert draft.dueMinute == 0
    assert "whatsapp" in draft.channels

def test_reminder_proposal_requires_confirmation():
    draft = ReminderDraft(title="Team Standup", priority="medium")
    proposal = ReminderProposal(
        status="PROPOSED",
        action="create_reminder",
        requires_confirmation=True,
        raw_prompt="Remind me tomorrow for team standup",
        draft=draft,
    )
    assert proposal.requires_confirmation is True
    assert proposal.status == "PROPOSED"
    assert proposal.action == "create_reminder"

def test_create_reminder_tool_execution():
    proposal_tracker.reset()

    result = create_reminder(
        title="Doctor Appointment",
        description="Bring blood test reports",
        due_date="2026-09-22",
        due_hour=10,
        due_minute=30,
        priority="HIGH",
        recurrence="NONE",
        channels=["local", "whatsapp"],
        url=None,
        reasoning="Medical appointment marked high priority",
    )

    assert result["status"] == "PROPOSED"
    assert result["action"] == "create_reminder"
    assert result["requires_confirmation"] is True
    assert result["draft"]["title"] == "Doctor Appointment"
    assert result["draft"]["priority"] == "high"
    assert result["draft"]["recurrence"] == "none"
    assert result["draft"]["dueHour"] == 10
    assert result["draft"]["dueMinute"] == 30
    assert "whatsapp" in result["draft"]["channels"]

    captured = proposal_tracker.get_proposal()
    assert captured is not None
    assert captured["draft"]["title"] == "Doctor Appointment"
    assert proposal_tracker.get_call_count() == 1

def test_create_reminder_tool_defaults_and_normalization():
    result = create_reminder(
        title="Casual Walk",
        priority="INVALID_PRIORITY",
        recurrence="INVALID_RECURRENCE",
    )
    assert result["draft"]["priority"] == "medium"
    assert result["draft"]["recurrence"] == "none"
    assert result["draft"]["channels"] == ["local", "whatsapp"]

def test_openai_provider_status():
    provider = OpenAIProvider(api_key="sk-test-key", model="gpt-4o-mini")
    status = provider.get_status_info()
    assert status["ai_provider"] == "openai"
    assert status["model"] == "gpt-4o-mini"
    assert status["configured"] is True

def test_health_endpoint():
    client = TestClient(app)
    response = client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "healthy"
    assert data["ai_provider"] == "openai"
    assert "model" in data

def test_create_reminder_endpoint_validation():
    client = TestClient(app)
    response = client.post("/agent/reminder", json={"prompt": ""})
    assert response.status_code == 400

def test_create_reminder_endpoint_with_mocked_agent(monkeypatch):
    client = TestClient(app)
    
    mock_draft = ReminderDraft(
        title="Amazon interview",
        description="prepare interview questions",
        dueDate="2026-09-21",
        dueHour=21,
        dueMinute=0,
        priority="high",
        recurrence="none",
        channels=["local", "whatsapp"],
        reasoning="Identified high priority interview reminder for tomorrow 9 PM.",
    )
    mock_proposal = ReminderProposal(
        status="PROPOSED",
        action="create_reminder",
        requires_confirmation=True,
        raw_prompt="Remind me tomorrow at 9 PM about my Amazon interview",
        draft=mock_draft,
    )
    mock_response = AgentResponse(
        success=True,
        proposal=mock_proposal,
        message="I have proposed an Amazon interview reminder for tomorrow at 9:00 PM.",
    )

    async def mock_async_process(**kwargs):
        return mock_response

    from agent.app import agent
    monkeypatch.setattr(agent, "process_prompt_async", mock_async_process)

    payload = {
        "prompt": "Remind me tomorrow at 9 PM about my Amazon interview because I need to prepare interview questions.",
        "current_date": "2026-09-20",
        "current_time": "04:20",
    }
    res = client.post("/agent/reminder", json=payload)
    assert res.status_code == 200
    body = res.json()
    assert body["success"] is True
    assert body["proposal"]["requires_confirmation"] is True
    assert body["proposal"]["draft"]["title"] == "Amazon interview"
    assert body["proposal"]["draft"]["dueHour"] == 21
    assert body["proposal"]["draft"]["dueMinute"] == 0
    assert "whatsapp" in body["proposal"]["draft"]["channels"]

def test_system_prompt_rules():
    agent_inst = ReminderAgent.__new__(ReminderAgent)
    prompt = agent_inst._build_system_prompt("2026-09-20", "05:00")
    assert "Call the `create_reminder` tool EXACTLY ONCE" in prompt
    assert "present a brief confirmation to the user in text" in prompt
    assert "You must NOT call `create_reminder` again for the same request." in prompt

def test_extract_fallback_proposal():
    agent_inst = ReminderAgent.__new__(ReminderAgent)
    sample_text = """
The reminder has been created with the following details:  
**Title:** Amazon interview  
**Description:** I need to prepare interview questions  
**Due Date:** 2026-09-21  
**Due Time:** 21:00  
**Priority:** High  
**Recurrence:** None  
"""
    proposal = agent_inst._extract_fallback_proposal(sample_text, "test prompt")
    assert proposal is not None
    assert proposal.status == "PROPOSED"
    assert proposal.action == "create_reminder"
    assert proposal.requires_confirmation is True
    assert proposal.draft.title == "Amazon interview"
    assert proposal.draft.dueDate == "2026-09-21"
    assert proposal.draft.dueHour == 21
    assert proposal.draft.dueMinute == 0
    assert proposal.draft.priority == "high"
    assert proposal.draft.recurrence == "none"
    assert "whatsapp" in proposal.draft.channels

def test_action_router_local_only():
    import anyio
    async def _run():
        draft = ReminderDraft(
            title="Submit Project",
            dueDate="2026-09-21",
            channels=["local"],
        )
        router = ActionRouter()
        result = await router.route_confirmed_action(draft=draft)
        assert result["success"] is True
        assert "local" in result["channels_dispatched"]

    anyio.run(_run)

def test_action_router_with_unconfigured_whatsapp():
    import anyio
    async def _run():
        draft = ReminderDraft(
            title="Doctor Appointment",
            dueDate="2026-09-21",
            dueHour=10,
            dueMinute=0,
            channels=["local", "whatsapp"],
        )
        twilio_service = TwilioWhatsAppService(account_sid=None, auth_token=None, from_number=None)
        router = ActionRouter(whatsapp_service=twilio_service)
        result = await router.route_confirmed_action(draft=draft, user_phone_number="+1234567890")
        assert result["success"] is True
        assert "local" in result["channels_dispatched"]
        assert result["results"]["whatsapp"]["status"] == "NOT_CONFIGURED"

    anyio.run(_run)

def test_action_confirm_endpoint():
    client = TestClient(app)
    payload = {
        "action": "confirm_reminder",
        "draft": {
            "title": "Amazon Interview",
            "dueDate": "2026-09-21",
            "dueHour": 9,
            "dueMinute": 0,
            "priority": "high",
            "recurrence": "none",
            "channels": ["local", "whatsapp"]
        },
        "user_phone_number": "+1234567890"
    }
    response = client.post("/action/confirm", json=payload)
    assert response.status_code == 200
    data = response.json()
    assert data["success"] is True
    assert data["status"] == "ROUTED"
    assert "local" in data["channels_dispatched"]

def test_reminder_agent_unconfigured_openai_graceful_response():
    import anyio
    async def _run():
        provider = OpenAIProvider(api_key="")
        agent_inst = ReminderAgent(provider=provider)
        res = await agent_inst.process_prompt_async("Remind me tomorrow at 9 AM to call mom")
        assert res.success is False
        assert "OpenAI API is not configured" in res.error

    anyio.run(_run)

def test_password_hashing_and_verification():
    raw_pass = "SecureP@ssw0rd123!"
    hashed = hash_password(raw_pass)
    assert hashed.startswith("pbkdf2:sha256:")
    assert verify_password(raw_pass, hashed) is True
    assert verify_password("WrongPassword!", hashed) is False

def test_database_initialization_and_schema():
    init_db()
    engine = get_db_engine()
    from sqlalchemy import inspect
    inspector = inspect(engine)
    table_names = inspector.get_table_names()
    assert "users" in table_names
    assert "reminders" in table_names
    assert "reminder_channels" in table_names
    assert "phone_verifications" in table_names
    assert "action_history" in table_names

def test_parse_due_date_iso_formats():
    # 1. Full Flutter ISO-8601 with milliseconds
    assert parse_due_date("2026-10-01T00:00:00.000") == date(2026, 10, 1)

    # 2. Standard YYYY-MM-DD
    assert parse_due_date("2026-10-01") == date(2026, 10, 1)

    # 3. ISO datetime without milliseconds
    assert parse_due_date("2026-10-01T15:30:00") == date(2026, 10, 1)

    # 4. ISO datetime ending with UTC 'Z'
    assert parse_due_date("2026-10-01T15:30:00Z") == date(2026, 10, 1)
    assert parse_due_date("2026-10-01T15:30:00.000Z") == date(2026, 10, 1)

    # 5. None and empty string
    assert parse_due_date(None) is None
    assert parse_due_date("") is None
    assert parse_due_date("   ") is None

def test_action_confirm_persists_full_iso_due_date():
    client = TestClient(app)
    payload = {
        "action": "confirm_reminder",
        "draft": {
            "title": "Assignment Submission",
            "dueDate": "2026-10-01T00:00:00.000",
            "dueHour": 18,
            "dueMinute": 0,
            "priority": "high",
            "recurrence": "none",
            "channels": ["local", "whatsapp"]
        },
        "user_phone_number": "+1987654321"
    }
    response = client.post("/action/confirm", json=payload)
    assert response.status_code == 200
    data = response.json()
    assert data["success"] is True

    # Verify that the reminder record in the database persisted the parsed date, NOT NULL
    session = next(get_db_session())
    try:
        created_reminder = (
            session.query(Reminder)
            .filter_by(title="Assignment Submission")
            .order_by(Reminder.created_at.desc())
            .first()
        )
        assert created_reminder is not None
        assert created_reminder.due_date == date(2026, 10, 1)
        assert created_reminder.status == "CONFIRMED"

        # Cleanup test record
        session.delete(created_reminder)
        session.commit()
    finally:
        session.close()
