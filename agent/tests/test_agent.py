from datetime import date, datetime, timedelta, timezone
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

# ============================================================================
# Step 5: Backend Authentication & JWT Verification Tests
# ============================================================================

from agent.services.jwt_service import (
    create_access_token,
    decode_access_token,
    get_jwt_secret,
)
from agent.database.models import PhoneVerification
from datetime import timedelta
import uuid
import jwt

def _unique_test_phone():
    return f"+1999{uuid.uuid4().int % 10000000:07d}"

def test_auth_signup_success():
    client = TestClient(app)
    unique_phone = _unique_test_phone()

    payload = {
        "name": "Alice Tester",
        "phone_number": unique_phone,
        "password": "Password123!",
    }
    response = client.post("/auth/signup", json=payload)
    assert response.status_code == 200
    data = response.json()
    assert data["success"] is True
    assert data["user_id"] is not None
    assert data["name"] == "Alice Tester"
    assert data["phone_number"] == unique_phone
    assert data["is_verified"] is False
    assert data["token"] is not None

    # Verify password was hashed (never stored plaintext)
    session = next(get_db_session())
    try:
        user = session.query(User).filter_by(id=data["user_id"]).first()
        assert user is not None
        assert user.password_hash != "Password123!"
        assert verify_password("Password123!", user.password_hash) is True
    finally:
        session.close()

def test_auth_signup_duplicate_rejected():
    client = TestClient(app)
    unique_phone = _unique_test_phone()
    payload = {
        "name": "Bob Duplicate",
        "phone_number": unique_phone,
        "password": "Password123!",
    }
    res1 = client.post("/auth/signup", json=payload)
    assert res1.status_code == 200

    # Attempt duplicate signup
    res2 = client.post("/auth/signup", json=payload)
    assert res2.status_code == 400
    data = res2.json()
    assert data["success"] is False
    assert "already registered" in data["message"].lower()

def test_auth_signin_success():
    client = TestClient(app)
    unique_phone = _unique_test_phone()
    client.post("/auth/signup", json={
        "name": "Charlie Signin",
        "phone_number": unique_phone,
        "password": "CorrectPassword123",
    })

    response = client.post("/auth/signin", json={
        "phone_number": unique_phone,
        "password": "CorrectPassword123",
    })
    assert response.status_code == 200
    data = response.json()
    assert data["success"] is True
    assert data["token"] is not None
    assert data["name"] == "Charlie Signin"

def test_auth_signin_wrong_password():
    client = TestClient(app)
    unique_phone = _unique_test_phone()
    client.post("/auth/signup", json={
        "name": "Danielle WrongPw",
        "phone_number": unique_phone,
        "password": "RealPassword123",
    })

    response = client.post("/auth/signin", json={
        "phone_number": unique_phone,
        "password": "WrongPassword999",
    })
    assert response.status_code == 401
    data = response.json()
    assert data["success"] is False
    assert "invalid" in data["message"].lower()

def test_auth_signin_unknown_phone():
    client = TestClient(app)
    response = client.post("/auth/signin", json={
        "phone_number": "+19999999999",
        "password": "AnyPassword",
    })
    assert response.status_code == 401
    data = response.json()
    assert data["success"] is False
    assert "invalid" in data["message"].lower()

def test_jwt_token_generation_and_decode():
    token = create_access_token(
        user_id="usr-12345",
        phone_number="+15551234567",
        name="Token User",
        expires_delta=timedelta(hours=2),
    )
    assert token is not None
    claims = decode_access_token(token)
    assert claims["sub"] == "usr-12345"
    assert claims["phone"] == "+15551234567"
    assert claims["name"] == "Token User"
    assert "exp" in claims
    assert "iat" in claims

def test_missing_jwt_secret_configuration(monkeypatch):
    """Ensure missing or blank JWT secret fails cleanly without fallbacks."""
    monkeypatch.delenv("JWT_ACCESS_SECRET", raising=False)
    monkeypatch.setattr("agent.services.jwt_service._load_env_file", lambda: None)

    # 1. Direct secret retrieval raises RuntimeError
    with pytest.raises(RuntimeError, match="JWT_ACCESS_SECRET is required"):
        get_jwt_secret()

    # 2. Token generation fails without secret
    with pytest.raises(RuntimeError, match="JWT_ACCESS_SECRET is required"):
        create_access_token(user_id="test-uid")

    # 3. Token decoding fails without secret
    with pytest.raises(RuntimeError, match="JWT_ACCESS_SECRET is required"):
        decode_access_token("some.test.token")

    # 4. App startup fails cleanly without secret
    with pytest.raises(RuntimeError, match="JWT_ACCESS_SECRET is required"):
        with TestClient(app):
            pass

def test_jwt_error_handling_cases():
    """Verify explicit 401 status codes and messages across JWT failure modes."""
    client = TestClient(app)
    secret = get_jwt_secret()

    # 1. Missing Bearer token on protected route -> HTTP 401
    res_missing = client.get("/auth/me")
    assert res_missing.status_code == 401
    assert res_missing.json()["detail"] == "Authentication token required."

    # 2. Expired token -> HTTP 401 with explicit message
    expired_token = create_access_token(
        user_id="usr-expired",
        expires_delta=timedelta(seconds=-10),
    )
    res_exp = client.get("/auth/me", headers={"Authorization": f"Bearer {expired_token}"})
    assert res_exp.status_code == 401
    assert res_exp.json()["detail"] == "Token has expired."

    # 3. Malformed/invalid token -> HTTP 401
    res_bad = client.get("/auth/me", headers={"Authorization": "Bearer invalid.token.structure"})
    assert res_bad.status_code == 401
    assert res_bad.json()["detail"] == "Invalid authentication token."

    # 4. Valid signature but missing 'sub' claim -> HTTP 401
    now = datetime.now(timezone.utc)
    token_no_sub = jwt.encode(
        {"phone": "+15551234567", "exp": int((now + timedelta(hours=1)).timestamp())},
        secret,
        algorithm="HS256",
    )
    res_no_sub = client.get("/auth/me", headers={"Authorization": f"Bearer {token_no_sub}"})
    assert res_no_sub.status_code == 401
    assert res_no_sub.json()["detail"] == "Invalid token claims."

    # 5. User referenced by token does not exist in database -> HTTP 401
    nonexistent_user_token = create_access_token(user_id="nonexistent-user-id-9999")
    res_ghost = client.get("/auth/me", headers={"Authorization": f"Bearer {nonexistent_user_token}"})
    assert res_ghost.status_code == 401
    assert res_ghost.json()["detail"] == "User not found."

def test_phone_verification_state_transition():
    client = TestClient(app)
    unique_phone = _unique_test_phone()
    signup_res = client.post("/auth/signup", json={
        "name": "Eva Verify",
        "phone_number": unique_phone,
        "password": "SecretPassword123",
    })
    assert signup_res.status_code == 200
    user_id = signup_res.json()["user_id"]

    # Attempt wrong verification code
    bad_verify = client.post("/auth/verify-phone", json={
        "phone_number": unique_phone,
        "verification_code": "000000",
    })
    assert bad_verify.status_code == 400
    assert bad_verify.json()["success"] is False

    # Perform correct verification code ("123456" in dev/test)
    good_verify = client.post("/auth/verify-phone", json={
        "phone_number": unique_phone,
        "verification_code": "123456",
    })
    assert good_verify.status_code == 200
    data = good_verify.json()
    assert data["success"] is True
    assert data["is_verified"] is True

    # Verify user record in database has phone_verified = True
    session = next(get_db_session())
    try:
        user = session.query(User).filter_by(id=user_id).first()
        assert user is not None
        assert user.phone_verified is True
    finally:
        session.close()

def test_authenticated_reminder_request_uses_user_id():
    client = TestClient(app)
    unique_phone = _unique_test_phone()
    signup_res = client.post("/auth/signup", json={
        "name": "Frank AuthReminder",
        "phone_number": unique_phone,
        "password": "Password123!",
    })
    assert signup_res.status_code == 200
    token = signup_res.json()["token"]
    user_id = signup_res.json()["user_id"]

    # Confirm reminder with Authorization Bearer header
    confirm_payload = {
        "action": "confirm_reminder",
        "draft": {
            "title": "Authenticated Project Review",
            "dueDate": "2026-10-05T00:00:00.000",
            "dueHour": 14,
            "dueMinute": 0,
            "priority": "high",
            "recurrence": "none",
            "channels": ["local"],
        },
        "user_phone_number": unique_phone,
    }
    response = client.post(
        "/action/confirm",
        json=confirm_payload,
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    assert response.json()["success"] is True

    # Verify the created reminder is assigned to Frank's user_id, NOT guest
    session = next(get_db_session())
    try:
        reminder = (
            session.query(Reminder)
            .filter_by(title="Authenticated Project Review")
            .order_by(Reminder.created_at.desc())
            .first()
        )
        assert reminder is not None
        assert reminder.user_id == user_id
    finally:
        session.close()

def test_unauthenticated_protected_request_rejected():
    client = TestClient(app)
    # GET /auth/me without header
    response = client.get("/auth/me")
    assert response.status_code == 401
    assert response.json()["detail"] == "Authentication token required."

def test_strict_optional_auth_handling():
    """Verify that optional-auth endpoints allow unauthenticated guests,
    but strictly reject invalid, expired, or malformed tokens with HTTP 401."""
    client = TestClient(app)
    expired_token = create_access_token(
        user_id="usr-expired",
        expires_delta=timedelta(seconds=-10),
    )

    # 1. Unauthenticated guest to /action/confirm succeeds
    guest_payload = {
        "action": "confirm_reminder",
        "draft": {
            "title": "Strict Optional Auth Guest Task",
            "dueDate": "2026-10-06T00:00:00.000",
            "dueHour": 10,
            "dueMinute": 0,
            "channels": ["local"],
        },
    }
    res_guest = client.post("/action/confirm", json=guest_payload)
    assert res_guest.status_code == 200
    assert res_guest.json()["success"] is True

    # 2. Invalid Bearer token to /action/confirm rejects with HTTP 401 (not silent guest fallback)
    res_bad_token = client.post(
        "/action/confirm",
        json=guest_payload,
        headers={"Authorization": "Bearer bad.token.string"},
    )
    assert res_bad_token.status_code == 401
    assert res_bad_token.json()["detail"] == "Invalid authentication token."

    # 3. Expired Bearer token to /action/confirm rejects with HTTP 401
    res_exp_token = client.post(
        "/action/confirm",
        json=guest_payload,
        headers={"Authorization": f"Bearer {expired_token}"},
    )
    assert res_exp_token.status_code == 401
    assert res_exp_token.json()["detail"] == "Token has expired."

    # 4. Non-Bearer / malformed Authorization header rejects with HTTP 401
    res_non_bearer = client.post(
        "/action/confirm",
        json=guest_payload,
        headers={"Authorization": "Basic somecredentials"},
    )
    assert res_non_bearer.status_code == 401
    assert res_non_bearer.json()["detail"] == "Invalid authentication token."

    # 5. Invalid Bearer token to /agent/reminder rejects with HTTP 401
    res_reminder_bad = client.post(
        "/agent/reminder",
        json={"prompt": "Doctor visit tomorrow"},
        headers={"Authorization": "Bearer bad.token.string"},
    )
    assert res_reminder_bad.status_code == 401
    assert res_reminder_bad.json()["detail"] == "Invalid authentication token."

# ============================================================================
# Phase 6: Cloud Synchronization & Authenticated Reminder CRUD Tests
# ============================================================================

def _create_authenticated_test_user(client: TestClient, name_prefix: str = "SyncUser"):
    phone = _unique_test_phone()
    res = client.post("/auth/signup", json={
        "name": f"{name_prefix} Test",
        "phone_number": phone,
        "password": "Password123!",
    })
    assert res.status_code == 200
    data = res.json()
    return {
        "user_id": data["user_id"],
        "token": data["token"],
        "phone": phone,
    }

def test_authenticated_user_can_get_own_reminders_and_isolation():
    client = TestClient(app)
    user_a = _create_authenticated_test_user(client, "UserA")
    user_b = _create_authenticated_test_user(client, "UserB")

    # User A creates two reminders
    r_a1 = client.post("/reminders", json={
        "title": "A Reminder 1",
        "due_date": "2026-10-10",
        "priority": "high",
    }, headers={"Authorization": f"Bearer {user_a['token']}"})
    assert r_a1.status_code == 201

    r_a2 = client.post("/reminders", json={
        "title": "A Reminder 2",
        "due_date": "2026-10-11",
        "priority": "low",
    }, headers={"Authorization": f"Bearer {user_a['token']}"})
    assert r_a2.status_code == 201

    # User B creates one reminder
    r_b1 = client.post("/reminders", json={
        "title": "B Reminder 1",
        "due_date": "2026-10-12",
        "priority": "medium",
    }, headers={"Authorization": f"Bearer {user_b['token']}"})
    assert r_b1.status_code == 201

    # User A fetches reminders -> sees A1 and A2, never B1
    res_a = client.get("/reminders", headers={"Authorization": f"Bearer {user_a['token']}"})
    assert res_a.status_code == 200
    items_a = res_a.json()
    assert len(items_a) == 2
    titles_a = [item["title"] for item in items_a]
    assert "A Reminder 1" in titles_a
    assert "A Reminder 2" in titles_a
    assert "B Reminder 1" not in titles_a
    # Deterministic order: check all items have user_id equal to user A
    for item in items_a:
        assert item["user_id"] == user_a["user_id"]

    # User B fetches reminders -> sees B1, never A's reminders
    res_b = client.get("/reminders", headers={"Authorization": f"Bearer {user_b['token']}"})
    assert res_b.status_code == 200
    items_b = res_b.json()
    assert len(items_b) == 1
    assert items_b[0]["title"] == "B Reminder 1"
    assert items_b[0]["user_id"] == user_b["user_id"]

def test_post_reminder_ignores_client_supplied_user_id():
    client = TestClient(app)
    user_a = _create_authenticated_test_user(client, "UserA")
    user_b = _create_authenticated_test_user(client, "UserB")

    # User A attempts to spoof user_id as user B
    spoof_payload = {
        "title": "Spoofed Ownership Reminder",
        "due_date": "2026-10-15",
        "user_id": user_b["user_id"],
    }
    res = client.post("/reminders", json=spoof_payload, headers={"Authorization": f"Bearer {user_a['token']}"})
    assert res.status_code == 201
    created = res.json()
    # The reminder MUST belong to User A, ignoring the spoofed user_id
    assert created["user_id"] == user_a["user_id"]
    assert created["user_id"] != user_b["user_id"]

def test_user_can_update_own_reminder():
    client = TestClient(app)
    user = _create_authenticated_test_user(client, "UpdateUser")

    # Create reminder
    create_res = client.post("/reminders", json={
        "title": "Initial Title",
        "due_date": "2026-10-20",
        "due_hour": 9,
        "due_minute": 0,
        "priority": "low",
    }, headers={"Authorization": f"Bearer {user['token']}"})
    assert create_res.status_code == 201
    reminder_id = create_res.json()["id"]

    # Update reminder
    update_res = client.put(f"/reminders/{reminder_id}", json={
        "title": "Updated Title",
        "due_date": "2026-10-21",
        "due_hour": 15,
        "due_minute": 30,
        "priority": "high",
        "status": "COMPLETED",
    }, headers={"Authorization": f"Bearer {user['token']}"})
    assert update_res.status_code == 200
    updated = update_res.json()
    assert updated["id"] == reminder_id
    assert updated["title"] == "Updated Title"
    assert updated["due_date"] == "2026-10-21"
    assert updated["due_hour"] == 15
    assert updated["due_minute"] == 30
    assert updated["priority"] == "high"
    assert updated["status"] == "COMPLETED"
    assert updated["user_id"] == user["user_id"]

def test_user_cannot_update_another_user_reminder():
    client = TestClient(app)
    user_a = _create_authenticated_test_user(client, "OwnerA")
    user_b = _create_authenticated_test_user(client, "AttackerB")

    # User A creates reminder
    create_res = client.post("/reminders", json={
        "title": "Private User A Reminder",
        "due_date": "2026-10-20",
    }, headers={"Authorization": f"Bearer {user_a['token']}"})
    assert create_res.status_code == 201
    reminder_id = create_res.json()["id"]

    # User B attempts to update User A's reminder -> returns 404
    update_res = client.put(f"/reminders/{reminder_id}", json={
        "title": "Hacked Title",
    }, headers={"Authorization": f"Bearer {user_b['token']}"})
    assert update_res.status_code == 404
    assert update_res.json()["detail"] == "Reminder not found."

def test_user_can_delete_own_reminder():
    client = TestClient(app)
    user = _create_authenticated_test_user(client, "DeleteUser")

    # Create reminder
    create_res = client.post("/reminders", json={
        "title": "To Be Deleted",
        "due_date": "2026-10-22",
    }, headers={"Authorization": f"Bearer {user['token']}"})
    assert create_res.status_code == 201
    reminder_id = create_res.json()["id"]

    # Delete reminder
    del_res = client.delete(f"/reminders/{reminder_id}", headers={"Authorization": f"Bearer {user['token']}"})
    assert del_res.status_code == 200
    assert del_res.json()["success"] is True

    # Verify it is no longer returned in GET /reminders
    get_res = client.get("/reminders", headers={"Authorization": f"Bearer {user['token']}"})
    assert get_res.status_code == 200
    ids = [item["id"] for item in get_res.json()]
    assert reminder_id not in ids

def test_user_cannot_delete_another_user_reminder():
    client = TestClient(app)
    user_a = _create_authenticated_test_user(client, "DelOwnerA")
    user_b = _create_authenticated_test_user(client, "DelAttackerB")

    # User A creates reminder
    create_res = client.post("/reminders", json={
        "title": "User A Undeletable by B",
        "due_date": "2026-10-23",
    }, headers={"Authorization": f"Bearer {user_a['token']}"})
    assert create_res.status_code == 201
    reminder_id = create_res.json()["id"]

    # User B attempts to delete User A's reminder -> returns 404
    del_res = client.delete(f"/reminders/{reminder_id}", headers={"Authorization": f"Bearer {user_b['token']}"})
    assert del_res.status_code == 404
    assert del_res.json()["detail"] == "Reminder not found."

    # User A verifies reminder is still intact
    get_res = client.get("/reminders", headers={"Authorization": f"Bearer {user_a['token']}"})
    assert get_res.status_code == 200
    ids = [item["id"] for item in get_res.json()]
    assert reminder_id in ids

def test_reminder_endpoints_reject_invalid_authentication():
    client = TestClient(app)

    # 1. GET /reminders without token -> 401
    assert client.get("/reminders").status_code == 401

    # 2. GET /reminders with malformed token -> 401
    assert client.get("/reminders", headers={"Authorization": "Bearer malformed.bad.token"}).status_code == 401

    # 3. POST /reminders without token -> 401
    assert client.post("/reminders", json={"title": "No Auth"}).status_code == 401

    # 4. PUT /reminders/{id} without token -> 401
    assert client.put("/reminders/any-id", json={"title": "No Auth"}).status_code == 401

    # 5. DELETE /reminders/{id} without token -> 401
    assert client.delete("/reminders/any-id").status_code == 401

def test_reminder_post_and_put_reject_invalid_date():
    client = TestClient(app)
    user = _create_authenticated_test_user(client, "DateValidateUser")

    # POST with invalid date format -> 400
    res_bad_post = client.post("/reminders", json={
        "title": "Bad Date Reminder",
        "due_date": "completely-invalid-date",
    }, headers={"Authorization": f"Bearer {user['token']}"})
    assert res_bad_post.status_code == 400
    assert "Invalid due_date format" in res_bad_post.json()["detail"]

    # Create valid reminder first
    res_good = client.post("/reminders", json={
        "title": "Good Date Reminder",
        "due_date": "2026-10-25",
    }, headers={"Authorization": f"Bearer {user['token']}"})
    assert res_good.status_code == 201
    reminder_id = res_good.json()["id"]

    # PUT with invalid date format -> 400
    res_bad_put = client.put(f"/reminders/{reminder_id}", json={
        "due_date": "not-a-valid-date",
    }, headers={"Authorization": f"Bearer {user['token']}"})
    assert res_bad_put.status_code == 400
    assert "Invalid due_date format" in res_bad_put.json()["detail"]

def test_reminder_database_failure_returns_error(monkeypatch):
    client = TestClient(app)
    user = _create_authenticated_test_user(client, "DbFailUser")

    from sqlalchemy.orm import Session
    from sqlalchemy.exc import SQLAlchemyError

    def failing_commit(self):
        raise SQLAlchemyError("Simulated database disk failure")

    monkeypatch.setattr(Session, "commit", failing_commit)

    # Attempt POST /reminders during database outage
    res = client.post("/reminders", json={
        "title": "Crash Test Reminder",
        "due_date": "2026-10-30",
    }, headers={"Authorization": f"Bearer {user['token']}"})

    # Must return HTTP 500 error, never fake success
    assert res.status_code == 500
    assert "Failed to persist reminder" in res.json()["detail"]


# ============================================================================
# Phase 7: Twilio WhatsApp Integration Tests
# ============================================================================

from agent.services.twilio_whatsapp_service import TwilioWhatsAppService
from agent.database.models import PendingWhatsAppConfirmation
from agent.routes.twilio_routes import set_reminder_agent

class MockAgentForTwilio:
    def __init__(self, title="Call Arun", due_date="2026-10-02", due_hour=18, due_minute=0):
        self.draft = ReminderDraft(
            title=title,
            dueDate=due_date,
            dueHour=due_hour,
            dueMinute=due_minute,
            priority="medium",
            channels=["local", "whatsapp"],
        )
        self.call_count = 0
        self.last_prompt = None

    async def process_prompt_async(self, prompt: str, current_date=None, current_time=None):
        self.call_count += 1
        self.last_prompt = prompt
        return AgentResponse(
            success=True,
            proposal=ReminderProposal(
                status="PROPOSED",
                action="create_reminder",
                requires_confirmation=True,
                raw_prompt=prompt,
                draft=self.draft,
            ),
            message="Reminder proposal generated successfully.",
        )

def _create_verified_test_user(client: TestClient, name_prefix: str = "WhatsAppUser"):
    phone = _unique_test_phone()
    res = client.post("/auth/signup", json={
        "name": f"{name_prefix} Test",
        "phone_number": phone,
        "password": "Password123!",
    })
    assert res.status_code == 200
    data = res.json()
    user_id = data["user_id"]
    token = data["token"]

    v_res = client.post("/auth/verify-phone", json={
        "phone_number": phone,
        "verification_code": "123456",
    })
    assert v_res.status_code == 200
    assert v_res.json()["is_verified"] is True

    return {
        "user_id": user_id,
        "token": token,
        "phone": phone,
    }

def test_whatsapp_normal_reminder_reaches_agent_and_stores_pending():
    """1, 6, 7: Valid WhatsApp webhook request reaches AI agent and creates pending confirmation."""
    client = TestClient(app)
    user = _create_verified_test_user(client, "TwilioUser1")
    mock_agent = MockAgentForTwilio(title="Call Arun", due_date="2026-10-02", due_hour=18, due_minute=0)
    set_reminder_agent(mock_agent)

    try:
        # User sends WhatsApp reminder request
        res = client.post("/webhooks/twilio/whatsapp", data={
            "From": f"whatsapp:{user['phone']}",
            "To": "whatsapp:+14155238886",
            "Body": "Remind me to call Arun tomorrow at 6 PM",
            "MessageSid": "SM1234567890",
        })

        assert res.status_code == 200
        assert res.headers["content-type"].startswith("application/xml")
        xml_text = res.text
        assert "📋 I understood:" in xml_text
        assert "Call Arun" in xml_text
        assert "Reply YES to confirm or NO to cancel." in xml_text
        assert mock_agent.call_count == 1
        assert mock_agent.last_prompt == "Remind me to call Arun tomorrow at 6 PM"

        # Verify DB pending confirmation is stored with PENDING status
        session = next(get_db_session())
        try:
            pending = (
                session.query(PendingWhatsAppConfirmation)
                .filter_by(user_id=user["user_id"], phone_number=user["phone"])
                .order_by(PendingWhatsAppConfirmation.created_at.desc())
                .first()
            )
            assert pending is not None
            assert pending.status == "PENDING"
            assert "Call Arun" in pending.proposed_draft

            # Verify ActionHistory recorded PROPOSE_REMINDER
            history = (
                session.query(ActionHistory)
                .filter_by(user_id=user["user_id"], action_type="PROPOSE_REMINDER")
                .order_by(ActionHistory.id.desc())
                .first()
            )
            assert history is not None
            assert "Call Arun" in history.details

            # Verify no reminder in reminders table yet (Human-in-the-loop requirement)
            reminders = session.query(Reminder).filter_by(user_id=user["user_id"]).all()
            assert len(reminders) == 0
        finally:
            session.close()
    finally:
        set_reminder_agent(None)

def test_whatsapp_empty_message_handled_safely():
    """2: Empty message does not crash and prompts user for reminder text."""
    client = TestClient(app)
    user = _create_verified_test_user(client, "TwilioEmpty")

    res = client.post("/webhooks/twilio/whatsapp", data={
        "From": f"whatsapp:{user['phone']}",
        "To": "whatsapp:+14155238886",
        "Body": "   ",
        "MessageSid": "SMempty",
    })

    assert res.status_code == 200
    assert "Please send a reminder request" in res.text

    session = next(get_db_session())
    try:
        count = session.query(PendingWhatsAppConfirmation).filter_by(user_id=user["user_id"]).count()
        assert count == 0
    finally:
        session.close()

def test_whatsapp_unknown_phone_number_rejected():
    """3: Unknown phone number receives unlinked message without creating reminders."""
    client = TestClient(app)
    unknown_phone = "+19998887777"

    res = client.post("/webhooks/twilio/whatsapp", data={
        "From": f"whatsapp:{unknown_phone}",
        "To": "whatsapp:+14155238886",
        "Body": "Remind me to buy milk",
        "MessageSid": "SMunknown",
    })

    assert res.status_code == 200
    assert "Your WhatsApp number is not linked to a Don't Miss account" in res.text

def test_whatsapp_unverified_phone_number_rejected():
    """4: Unverified phone number receives unlinked message."""
    client = TestClient(app)
    unverified_phone = _unique_test_phone()
    # Sign up but DO NOT verify phone
    signup_res = client.post("/auth/signup", json={
        "name": "Unverified User",
        "phone_number": unverified_phone,
        "password": "Password123!",
    })
    assert signup_res.status_code == 200

    res = client.post("/webhooks/twilio/whatsapp", data={
        "From": f"whatsapp:{unverified_phone}",
        "To": "whatsapp:+14155238886",
        "Body": "Remind me to submit homework",
        "MessageSid": "SMunverified",
    })

    assert res.status_code == 200
    assert "Your WhatsApp number is not linked to a Don't Miss account" in res.text

def test_whatsapp_verified_phone_maps_to_correct_user_and_ignores_spoofed_id():
    """5: Verified phone number maps to correct user and ignores forged user_id in payload."""
    client = TestClient(app)
    user_real = _create_verified_test_user(client, "RealUser")
    user_victim = _create_verified_test_user(client, "VictimUser")

    mock_agent = MockAgentForTwilio(title="Doctor visit")
    set_reminder_agent(mock_agent)

    try:
        # Real user attempts to spoof victim's user_id
        res = client.post("/webhooks/twilio/whatsapp", data={
            "From": f"whatsapp:{user_real['phone']}",
            "To": "whatsapp:+14155238886",
            "Body": "Remind me about doctor visit",
            "user_id": user_victim["user_id"],
        })
        assert res.status_code == 200
        assert "Doctor visit" in res.text

        session = next(get_db_session())
        try:
            pending = (
                session.query(PendingWhatsAppConfirmation)
                .filter_by(phone_number=user_real["phone"])
                .first()
            )
            assert pending is not None
            # Must be assigned to RealUser, NEVER VictimUser
            assert pending.user_id == user_real["user_id"]
            assert pending.user_id != user_victim["user_id"]
        finally:
            session.close()
    finally:
        set_reminder_agent(None)

def test_whatsapp_yes_confirms_correct_proposal_and_creates_reminder():
    """8: YES confirms proposal, marks status CONFIRMED, and creates Reminder in database."""
    client = TestClient(app)
    user = _create_verified_test_user(client, "YesUser")
    mock_agent = MockAgentForTwilio(title="Doctor Appointment", due_date="2026-10-05", due_hour=14, due_minute=30)
    set_reminder_agent(mock_agent)

    try:
        # 1. Propose reminder
        res_prop = client.post("/webhooks/twilio/whatsapp", data={
            "From": f"whatsapp:{user['phone']}",
            "To": "whatsapp:+14155238886",
            "Body": "Remind me to see doctor on Oct 5 at 2:30 PM",
        })
        assert res_prop.status_code == 200
        assert "Doctor Appointment" in res_prop.text

        # 2. Confirm with case-insensitive 'YES'
        res_yes = client.post("/webhooks/twilio/whatsapp", data={
            "From": f"whatsapp:{user['phone']}",
            "To": "whatsapp:+14155238886",
            "Body": "YES",
        })
        assert res_yes.status_code == 200
        assert "✅ Reminder confirmed." in res_yes.text
        assert "Doctor Appointment" in res_yes.text

        # Verify DB records
        session = next(get_db_session())
        try:
            pending = session.query(PendingWhatsAppConfirmation).filter_by(user_id=user["user_id"]).first()
            assert pending.status == "CONFIRMED"

            reminders = session.query(Reminder).filter_by(user_id=user["user_id"]).all()
            assert len(reminders) == 1
            reminder = reminders[0]
            assert reminder.title == "Doctor Appointment"
            assert str(reminder.due_date) == "2026-10-05"
            assert reminder.due_hour == 14
            assert reminder.due_minute == 30
            assert reminder.status == "CONFIRMED"

            # Check action history record
            history = (
                session.query(ActionHistory)
                .filter_by(user_id=user["user_id"], action_type="CONFIRM_REMINDER")
                .first()
            )
            assert history is not None
        finally:
            session.close()
    finally:
        set_reminder_agent(None)

def test_whatsapp_no_cancels_proposal_and_creates_no_reminder():
    """9: NO cancels pending proposal and does NOT create a reminder."""
    client = TestClient(app)
    user = _create_verified_test_user(client, "CancelUser")
    mock_agent = MockAgentForTwilio(title="Buy New Laptop")
    set_reminder_agent(mock_agent)

    try:
        # 1. Propose reminder
        client.post("/webhooks/twilio/whatsapp", data={
            "From": f"whatsapp:{user['phone']}",
            "To": "whatsapp:+14155238886",
            "Body": "Remind me to buy new laptop",
        })

        # 2. Cancel with 'CANCEL'
        res_cancel = client.post("/webhooks/twilio/whatsapp", data={
            "From": f"whatsapp:{user['phone']}",
            "To": "whatsapp:+14155238886",
            "Body": "CANCEL",
        })
        assert res_cancel.status_code == 200
        assert "❌ Reminder cancelled." in res_cancel.text

        session = next(get_db_session())
        try:
            pending = session.query(PendingWhatsAppConfirmation).filter_by(user_id=user["user_id"]).first()
            assert pending.status == "CANCELLED"

            reminders = session.query(Reminder).filter_by(user_id=user["user_id"]).all()
            assert len(reminders) == 0

            history = (
                session.query(ActionHistory)
                .filter_by(user_id=user["user_id"], action_type="CANCEL_REMINDER")
                .first()
            )
            assert history is not None
        finally:
            session.close()
    finally:
        set_reminder_agent(None)

def test_whatsapp_expired_proposal_cannot_be_confirmed():
    """10: Expired proposal receives expiration notice and creates no reminder."""
    client = TestClient(app)
    user = _create_verified_test_user(client, "ExpireUser")
    mock_agent = MockAgentForTwilio(title="Pay Rent")
    set_reminder_agent(mock_agent)

    try:
        client.post("/webhooks/twilio/whatsapp", data={
            "From": f"whatsapp:{user['phone']}",
            "To": "whatsapp:+14155238886",
            "Body": "Remind me to pay rent tomorrow",
        })

        # Force proposal expiration in DB
        session = next(get_db_session())
        try:
            pending = session.query(PendingWhatsAppConfirmation).filter_by(user_id=user["user_id"]).first()
            pending.expires_at = datetime.now(timezone.utc) - timedelta(minutes=5)
            session.commit()
        finally:
            session.close()

        # Send YES after expiration
        res_late = client.post("/webhooks/twilio/whatsapp", data={
            "From": f"whatsapp:{user['phone']}",
            "To": "whatsapp:+14155238886",
            "Body": "YES",
        })
        assert res_late.status_code == 200
        assert "⌛ This reminder confirmation has expired." in res_late.text

        # Verify no reminder created
        session = next(get_db_session())
        try:
            pending = session.query(PendingWhatsAppConfirmation).filter_by(user_id=user["user_id"]).first()
            assert pending.status == "EXPIRED"
            reminders = session.query(Reminder).filter_by(user_id=user["user_id"]).all()
            assert len(reminders) == 0
        finally:
            session.close()
    finally:
        set_reminder_agent(None)

def test_whatsapp_already_confirmed_proposal_cannot_be_replayed_no_duplicates():
    """11, 13: Already-confirmed proposal cannot be replayed and duplicate reminders are prevented."""
    client = TestClient(app)
    user = _create_verified_test_user(client, "ReplayUser")
    mock_agent = MockAgentForTwilio(title="Team Sync")
    set_reminder_agent(mock_agent)

    try:
        # Propose
        client.post("/webhooks/twilio/whatsapp", data={
            "From": f"whatsapp:{user['phone']}",
            "To": "whatsapp:+14155238886",
            "Body": "Team sync tomorrow at 10 AM",
        })

        # Confirm 1
        res1 = client.post("/webhooks/twilio/whatsapp", data={
            "From": f"whatsapp:{user['phone']}",
            "To": "whatsapp:+14155238886",
            "Body": "YES",
        })
        assert res1.status_code == 200
        assert "✅ Reminder confirmed." in res1.text

        # Confirm replay 2
        res2 = client.post("/webhooks/twilio/whatsapp", data={
            "From": f"whatsapp:{user['phone']}",
            "To": "whatsapp:+14155238886",
            "Body": "YES",
        })
        assert res2.status_code == 200
        assert "This reminder has already been confirmed." in res2.text

        # Confirm count in database is exactly 1
        session = next(get_db_session())
        try:
            reminders = session.query(Reminder).filter_by(user_id=user["user_id"]).all()
            assert len(reminders) == 1
        finally:
            session.close()
    finally:
        set_reminder_agent(None)

def test_whatsapp_user_a_cannot_confirm_user_b_proposal():
    """12: User A cannot confirm User B's proposal (cross-user isolation)."""
    client = TestClient(app)
    user_a = _create_verified_test_user(client, "UserA")
    user_b = _create_verified_test_user(client, "UserB")

    mock_agent = MockAgentForTwilio(title="User B Secret Reminder")
    set_reminder_agent(mock_agent)

    try:
        # User B initiates proposal
        client.post("/webhooks/twilio/whatsapp", data={
            "From": f"whatsapp:{user_b['phone']}",
            "To": "whatsapp:+14155238886",
            "Body": "User B secret reminder",
        })

        # User A sends YES from User A's phone
        res_a = client.post("/webhooks/twilio/whatsapp", data={
            "From": f"whatsapp:{user_a['phone']}",
            "To": "whatsapp:+14155238886",
            "Body": "YES",
        })
        assert res_a.status_code == 200
        assert "You have no pending reminder confirmations." in res_a.text

        # Check User B's proposal remains PENDING and no reminder created for User A
        session = next(get_db_session())
        try:
            pending_b = session.query(PendingWhatsAppConfirmation).filter_by(user_id=user_b["user_id"]).first()
            assert pending_b.status == "PENDING"
            reminders_a = session.query(Reminder).filter_by(user_id=user_a["user_id"]).all()
            assert len(reminders_a) == 0
            reminders_b = session.query(Reminder).filter_by(user_id=user_b["user_id"]).all()
            assert len(reminders_b) == 0
        finally:
            session.close()
    finally:
        set_reminder_agent(None)

def test_twilio_whatsapp_service_handles_api_failure():
    """14: Twilio API failure is handled cleanly without exceptions leaking."""
    class FailingMessages:
        def create(self, **kwargs):
            raise Exception("Twilio 400 bad request: destination number invalid")

    class FailingClient:
        messages = FailingMessages()

    service = TwilioWhatsAppService(
        account_sid="ACmocked12345",
        auth_token="authtoken12345",
        from_number="+14155238886",
        client=FailingClient(),
    )

    result = service.send_message(to_number="+15551234567", body="Test message")
    assert result["success"] is False
    assert result["status"] == "FAILED"
    assert "Twilio API error" in result["error"]

def test_twilio_whatsapp_service_does_not_expose_credentials():
    """15: Twilio service does not expose credentials in error details or string representations."""
    secret_token = "super_secret_auth_token_value_xyz"
    service = TwilioWhatsAppService(
        account_sid="ACmocked999",
        auth_token=secret_token,
        from_number="+14155238886",
    )

    assert secret_token not in str(service)
    assert secret_token not in repr(service)

    # Empty payload handling
    res = service.send_message(to_number="", body="Hello")
    assert res["success"] is False
    assert secret_token not in str(res)


# ==============================================================================
# VERSION 3 TESTS: Scheduled WhatsApp Reminder Delivery
# ==============================================================================

def test_version3_reminder_creation_channels_stored_and_returned():
    """Version 3: Reminder creation with channels stores ReminderChannel rows and returns channels in response."""
    client = TestClient(app)
    user = _create_verified_test_user(client, "V3User1")
    token = user["token"]

    payload = {
        "title": "Dentist Checkup",
        "description": "Routine dental cleaning",
        "due_date": "2026-10-15",
        "due_hour": 15,
        "due_minute": 0,
        "priority": "high",
        "recurrence": "none",
        "channels": ["local", "whatsapp"],
        "status": "CONFIRMED",
    }
    res = client.post("/reminders", json=payload, headers={"Authorization": f"Bearer {token}"})
    assert res.status_code == 201
    data = res.json()
    assert set(data["channels"]) == {"local", "whatsapp"}

    session = next(get_db_session())
    try:
        channels = session.query(ReminderChannel).filter_by(reminder_id=data["id"]).all()
        channel_names = {c.channel for c in channels}
        assert channel_names == {"local", "whatsapp"}
        for c in channels:
            assert c.status == "PENDING"
            assert c.dispatched_at is None
    finally:
        session.close()

def test_version3_reminder_creation_local_only_does_not_create_whatsapp_channel():
    """Version 3: Reminder creation with only local channel does not register a whatsapp channel."""
    client = TestClient(app)
    user = _create_verified_test_user(client, "V3UserLocalOnly")
    token = user["token"]

    payload = {
        "title": "Offline Study Session",
        "due_date": "2026-10-16",
        "due_hour": 10,
        "due_minute": 0,
        "priority": "medium",
        "recurrence": "none",
        "channels": ["local"],
    }
    res = client.post("/reminders", json=payload, headers={"Authorization": f"Bearer {token}"})
    assert res.status_code == 201
    data = res.json()
    assert data["channels"] == ["local"]

    session = next(get_db_session())
    try:
        channels = session.query(ReminderChannel).filter_by(reminder_id=data["id"]).all()
        channel_names = [c.channel for c in channels]
        assert "whatsapp" not in channel_names
        assert "local" in channel_names
    finally:
        session.close()

def test_version3_scheduler_dispatches_due_whatsapp_reminder_to_verified_user():
    """Version 3: Scheduler dispatches due reminder via Twilio WhatsApp service to verified user."""
    from agent.services.reminder_scheduler import ReminderScheduler

    client = TestClient(app)
    user = _create_verified_test_user(client, "V3SchedulerUser")

    session = next(get_db_session())
    try:
        # Create due reminder
        reminder = Reminder(
            user_id=user["user_id"],
            title="Take Medicine",
            description="Prescription vitamins",
            due_date=date(2026, 10, 1),
            due_hour=8,
            due_minute=0,
            status="CONFIRMED",
        )
        session.add(reminder)
        session.commit()
        session.refresh(reminder)

        channel_entry = ReminderChannel(
            reminder_id=reminder.id,
            channel="whatsapp",
            status="PENDING",
        )
        session.add(channel_entry)
        session.commit()
        rem_id = reminder.id
    finally:
        session.close()

    # Mock WhatsApp service
    calls = []
    class MockWhatsApp:
        def send_reminder_sync(self, to_number, title, due_time, description="", priority="medium"):
            calls.append({"to_number": to_number, "title": title, "due_time": due_time})
            return {"success": True, "sid": "SM_mock_12345", "status": "QUEUED"}

    scheduler = ReminderScheduler(whatsapp_service=MockWhatsApp())
    test_now = datetime(2026, 10, 1, 9, 0, tzinfo=timezone.utc)

    session = next(get_db_session())
    try:
        results = scheduler.process_due_reminders(session, current_dt=test_now)
        my_result = next((r for r in results if r["reminder_id"] == rem_id), None)
        assert my_result is not None
        assert my_result["status"] == "DISPATCHED"
        assert my_result["sid"] == "SM_mock_12345"

        # Check DB state
        ch = session.query(ReminderChannel).filter_by(reminder_id=rem_id, channel="whatsapp").first()
        assert ch.status == "DISPATCHED"
        assert ch.dispatched_at is not None

        # Verify ActionHistory
        hist = session.query(ActionHistory).filter_by(reminder_id=rem_id, action_type="DISPATCH_WHATSAPP").first()
        assert hist is not None
        assert hist.success is True
        assert "SM_mock_12345" in hist.details
    finally:
        session.close()

    assert len(calls) >= 1
    call_for_user = next((c for c in calls if c["to_number"] == user["phone"]), None)
    assert call_for_user is not None
    assert call_for_user["title"] == "Take Medicine"

def test_version3_scheduler_skips_unverified_user_safely():
    """Version 3: Scheduler skips unverified users without crashing or calling Twilio."""
    from agent.services.reminder_scheduler import ReminderScheduler
    import uuid

    session = next(get_db_session())
    try:
        unverified_user = User(
            id=str(uuid.uuid4()),
            email=f"unverified_{uuid.uuid4().hex[:6]}@example.com",
            full_name="Unverified Scheduler User",
            phone_number="+15550009999",
            password_hash=hash_password("Pass123!"),
            phone_verified=False,
        )
        session.add(unverified_user)
        session.commit()

        reminder = Reminder(
            user_id=unverified_user.id,
            title="Unverified Test",
            due_date=date(2026, 10, 1),
            due_hour=8,
            due_minute=0,
            status="CONFIRMED",
        )
        session.add(reminder)
        session.commit()
        session.refresh(reminder)

        channel_entry = ReminderChannel(
            reminder_id=reminder.id,
            channel="whatsapp",
            status="PENDING",
        )
        session.add(channel_entry)
        session.commit()
        rem_id = reminder.id
    finally:
        session.close()

    calls = []
    class MockWhatsApp:
        def send_reminder_sync(self, **kwargs):
            calls.append(kwargs)
            return {"success": True}

    scheduler = ReminderScheduler(whatsapp_service=MockWhatsApp())
    test_now = datetime(2026, 10, 1, 9, 0, tzinfo=timezone.utc)

    session = next(get_db_session())
    try:
        results = scheduler.process_due_reminders(session, current_dt=test_now)
        my_result = next((r for r in results if r["reminder_id"] == rem_id), None)
        assert my_result is not None
        assert my_result["status"] == "SKIPPED_UNVERIFIED"

        ch = session.query(ReminderChannel).filter_by(reminder_id=rem_id, channel="whatsapp").first()
        assert ch.status == "SKIPPED_UNVERIFIED"

        hist = session.query(ActionHistory).filter_by(reminder_id=rem_id, action_type="DISPATCH_WHATSAPP").first()
        assert hist is not None
        assert hist.success is False
        assert "no verified phone number" in hist.details
    finally:
        session.close()

    assert not any(c.get("to_number") == "+15550009999" for c in calls)

def test_version3_scheduler_idempotency_prevents_duplicate_sends():
    """Version 3: Re-running scheduler does not re-dispatch already dispatched reminders."""
    from agent.services.reminder_scheduler import ReminderScheduler

    client = TestClient(app)
    user = _create_verified_test_user(client, "V3IdempotencyUser")

    session = next(get_db_session())
    try:
        reminder = Reminder(
            user_id=user["user_id"],
            title="Idempotency Run",
            due_date=date(2026, 10, 1),
            due_hour=8,
            due_minute=0,
            status="CONFIRMED",
        )
        session.add(reminder)
        session.commit()

        channel_entry = ReminderChannel(
            reminder_id=reminder.id,
            channel="whatsapp",
            status="PENDING",
        )
        session.add(channel_entry)
        session.commit()
        rem_id = reminder.id
    finally:
        session.close()

    calls = []
    class MockWhatsApp:
        def send_reminder_sync(self, **kwargs):
            calls.append(kwargs)
            return {"success": True, "sid": "SM_idemp_1"}

    scheduler = ReminderScheduler(whatsapp_service=MockWhatsApp())
    test_now = datetime(2026, 10, 1, 9, 0, tzinfo=timezone.utc)

    # First run: should dispatch
    session = next(get_db_session())
    try:
        res1 = scheduler.process_due_reminders(session, current_dt=test_now)
        my_res1 = next((r for r in res1 if r["reminder_id"] == rem_id), None)
        assert my_res1 is not None
        assert my_res1["status"] == "DISPATCHED"
    finally:
        session.close()

    # Second run: should find 0 pending channels to process for this reminder
    session = next(get_db_session())
    try:
        res2 = scheduler.process_due_reminders(session, current_dt=test_now)
        my_res2 = next((r for r in res2 if r["reminder_id"] == rem_id), None)
        assert my_res2 is None
    finally:
        session.close()

def test_version3_twilio_service_uses_content_sid_and_variables():
    """Version 3: TwilioWhatsAppService uses content_sid and content_variables when configured."""
    import json

    captured_kwargs = {}
    class MockMessages:
        def create(self, **kwargs):
            captured_kwargs.update(kwargs)
            class MockMsg:
                sid = "SM_template_success"
                status = "queued"
            return MockMsg()

    class MockTwilioClient:
        messages = MockMessages()

    service = TwilioWhatsAppService(
        account_sid="ACmock123",
        auth_token="authtoken123",
        from_number="+17372508034",
        content_sid="HXmocktemplate123",
        client=MockTwilioClient(),
    )

    res = service.send_reminder_sync(
        to_number="+15551112222",
        title="Doctor Appointment",
        due_time="2026-10-05 at 14:30",
        description="Checkup",
        priority="high",
    )

    assert res["success"] is True
    assert res["sid"] == "SM_template_success"
    assert captured_kwargs["from_"] == "whatsapp:+17372508034"
    assert captured_kwargs["to"] == "whatsapp:+15551112222"
    assert captured_kwargs["content_sid"] == "HXmocktemplate123"
    vars_parsed = json.loads(captured_kwargs["content_variables"])
    assert vars_parsed["1"] == "Doctor Appointment"
    assert vars_parsed["2"] == "2026-10-05 at 14:30"

def test_version3_scheduler_handles_twilio_failure_marks_failed():
    """Version 3: Twilio dispatch failure marks ReminderChannel as FAILED without raising an unhandled exception."""
    from agent.services.reminder_scheduler import ReminderScheduler

    client = TestClient(app)
    user = _create_verified_test_user(client, "V3FailUser")

    session = next(get_db_session())
    try:
        reminder = Reminder(
            user_id=user["user_id"],
            title="Failing Reminder",
            due_date=date(2026, 10, 1),
            due_hour=8,
            due_minute=0,
            status="CONFIRMED",
        )
        session.add(reminder)
        session.commit()

        channel_entry = ReminderChannel(
            reminder_id=reminder.id,
            channel="whatsapp",
            status="PENDING",
        )
        session.add(channel_entry)
        session.commit()
        rem_id = reminder.id
    finally:
        session.close()

    class FailingWhatsApp:
        def send_reminder_sync(self, **kwargs):
            return {"success": False, "status": "FAILED", "error": "Twilio gateway 503"}

    scheduler = ReminderScheduler(whatsapp_service=FailingWhatsApp())
    test_now = datetime(2026, 10, 1, 9, 0, tzinfo=timezone.utc)

    session = next(get_db_session())
    try:
        results = scheduler.process_due_reminders(session, current_dt=test_now)
        my_res = next((r for r in results if r["reminder_id"] == rem_id), None)
        assert my_res is not None
        assert my_res["status"] == "FAILED"

        ch = session.query(ReminderChannel).filter_by(reminder_id=rem_id, channel="whatsapp").first()
        assert ch.status == "FAILED"

        hist = session.query(ActionHistory).filter_by(reminder_id=rem_id, action_type="DISPATCH_WHATSAPP").first()
        assert hist is not None
        assert hist.success is False
        assert "Twilio gateway 503" in hist.details
    finally:
        session.close()




