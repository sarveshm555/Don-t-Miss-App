"""Targeted regression tests for principal engineering audit fixes."""

import asyncio
import json
import uuid
from datetime import date, datetime, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.orm import Session

from agent.app import app
from agent.database import connection as db_conn
from agent.database.connection import get_db_session, init_db
from agent.database.models import Reminder, ReminderChannel, User
from agent.models.reminder_schema import ReminderDraft
from agent.providers.openai_provider import OpenAIProvider
from agent.reminder_agent import ReminderAgent
from agent.services.jwt_service import (
    create_access_token,
    create_refresh_token,
    decode_access_token,
    decode_refresh_token,
)
from agent.services.password_service import hash_password
from agent.services.reminder_persistence import persist_confirmed_reminder_to_db
from agent.services.reminder_scheduler import ReminderScheduler


def _make_mock_choice(tool_calls=None, content=""):
    message = MagicMock()
    message.content = content
    message.tool_calls = tool_calls or []
    choice = MagicMock()
    choice.message = message
    completion = MagicMock()
    completion.choices = [choice]
    return completion


def _make_tool_call(name: str, args: dict, call_id: str = "call_reg_1"):
    tool_call = MagicMock()
    tool_call.id = call_id
    tool_call.function.name = name
    tool_call.function.arguments = json.dumps(args)
    return tool_call


@pytest.mark.anyio
async def test_concurrent_process_prompt_async_isolation():
    """Verify overlapping process_prompt_async calls do not clobber proposals."""
    mock_provider = MagicMock(spec=OpenAIProvider)
    mock_provider.is_configured = True
    mock_provider.model = "gpt-4o-mini"

    async def delayed_create(**kwargs):
        user_msg = kwargs["messages"][-1]["content"]
        if "yoga" in user_msg.lower():
            await asyncio.sleep(0.04)
            return _make_mock_choice(
                tool_calls=[
                    _make_tool_call(
                        "create_reminder",
                        {
                            "title": "Morning Yoga",
                            "description": "30-minute stretch",
                            "due_date": "2026-11-28",
                            "due_hour": 7,
                            "due_minute": 0,
                            "priority": "medium",
                            "recurrence": "daily",
                            "channels": ["local"],
                            "reasoning": "Daily morning routine",
                        },
                        call_id="call_yoga",
                    )
                ]
            )
        await asyncio.sleep(0.01)
        return _make_mock_choice(
            tool_calls=[
                _make_tool_call(
                    "create_reminder",
                    {
                        "title": "Submit Tax Report",
                        "description": "Include Q4 receipts",
                        "due_date": "2026-11-29",
                        "due_hour": 18,
                        "due_minute": 30,
                        "priority": "high",
                        "recurrence": "none",
                        "channels": ["local", "whatsapp"],
                        "reasoning": "Urgent financial deadline",
                    },
                    call_id="call_tax",
                )
            ]
        )

    mock_client = MagicMock()
    mock_client.chat.completions.create = AsyncMock(side_effect=delayed_create)
    mock_provider.get_async_client.return_value = mock_client

    agent_instance = ReminderAgent(provider=mock_provider)
    res_yoga, res_tax = await asyncio.gather(
        agent_instance.process_prompt_async(
            "Remind me tomorrow at 7 AM for yoga",
            current_date="2026-11-27",
            current_time="10:00",
            timezone="Asia/Kolkata",
        ),
        agent_instance.process_prompt_async(
            "On Nov 29 at 6:30 PM submit tax report with Q4 receipts",
            current_date="2026-11-27",
            current_time="10:00",
            timezone="America/New_York",
        ),
    )

    assert res_yoga.success is True
    assert res_tax.success is True
    assert res_yoga.proposal is not None
    assert res_tax.proposal is not None
    assert res_yoga.proposal.draft.title == "Morning Yoga"
    assert res_yoga.proposal.draft.timezone == "Asia/Kolkata"
    assert res_tax.proposal.draft.title == "Submit Tax Report"
    assert res_tax.proposal.draft.timezone == "America/New_York"


@pytest.mark.anyio
async def test_fallback_proposal_respects_timezone_and_rejects_past():
    """Verify fallback text extraction honors provided timezone and blocks past times."""
    mock_provider = MagicMock(spec=OpenAIProvider)
    mock_provider.is_configured = True
    mock_provider.model = "gpt-4o-mini"

    # Model returns plain text fallback format instead of tool call
    mock_client = MagicMock()
    mock_client.chat.completions.create = AsyncMock(
        return_value=_make_mock_choice(
            tool_calls=[],
            content=(
                "Title: Call Lecturer\n"
                "Description: Discuss thesis outline\n"
                "Due Date: 2026-11-27\n"
                "Due Time: 08:00"
            ),
        )
    )
    mock_provider.get_async_client.return_value = mock_client

    agent_instance = ReminderAgent(provider=mock_provider)

    # Requested time 08:00 is before cur_time 14:00 -> fallback must return None / error
    past_res = await agent_instance.process_prompt_async(
        "Call lecturer at 8 AM today",
        current_date="2026-11-27",
        current_time="14:00",
        timezone="America/Chicago",
    )
    assert past_res.success is False

    # Future fallback extraction preserves America/Chicago timezone
    mock_client.chat.completions.create = AsyncMock(
        return_value=_make_mock_choice(
            tool_calls=[],
            content=(
                "Title: Call Lecturer\n"
                "Description: Discuss thesis outline\n"
                "Due Date: 2026-11-28\n"
                "Due Time: 09:00"
            ),
        )
    )
    future_res = await agent_instance.process_prompt_async(
        "Call lecturer tomorrow at 9 AM",
        current_date="2026-11-27",
        current_time="14:00",
        timezone="America/Chicago",
    )
    assert future_res.success is True
    assert future_res.proposal is not None
    assert future_res.proposal.draft.timezone == "America/Chicago"
    assert future_res.proposal.draft.dueDate == "2026-11-28"


def test_init_db_adds_missing_completed_at_column(tmp_path):
    """Verify init_db idempotently migrates legacy reminders table missing completed_at."""
    legacy_db_path = tmp_path / "legacy_reminders.db"
    temp_engine = create_engine(
        f"sqlite:///{legacy_db_path}",
        connect_args={"check_same_thread": False},
    )
    with temp_engine.begin() as conn:
        conn.execute(
            text(
                """
                CREATE TABLE reminders (
                    id VARCHAR PRIMARY KEY,
                    user_id VARCHAR NOT NULL,
                    title VARCHAR NOT NULL,
                    status VARCHAR DEFAULT 'CONFIRMED'
                )
                """
            )
        )

    assert "completed_at" not in {
        c["name"] for c in inspect(temp_engine).get_columns("reminders")
    }

    orig_engine = db_conn._engine
    orig_session_local = db_conn._SessionLocal
    try:
        db_conn._engine = temp_engine
        db_conn._SessionLocal = None
        init_db()
        cols = {c["name"] for c in inspect(temp_engine).get_columns("reminders")}
        assert "completed_at" in cols
    finally:
        temp_engine.dispose()
        db_conn._engine = orig_engine
        db_conn._SessionLocal = orig_session_local


def test_persist_confirmed_reminder_no_duplicate_channels():
    """Verify updating an existing reminder via persist_confirmed_reminder_to_db deduplicates channels."""
    init_db()
    db: Session = next(get_db_session())
    try:
        user_id = str(uuid.uuid4())
        reminder_id = str(uuid.uuid4())
        phone = f"+1777{uuid.uuid4().int % 10000000:07d}"
        user = User(
            id=user_id,
            email=f"dedup_{user_id[:8]}@example.com",
            password_hash=hash_password("ValidPass123!"),
            full_name="Dedup Tester",
            phone_number=phone,
            phone_verified=True,
        )
        db.add(user)
        db.commit()

        draft = ReminderDraft(
            id=reminder_id,
            title="Submit Capstone",
            description="Upload PDF",
            dueDate="2026-12-01",
            dueHour=10,
            dueMinute=0,
            priority="high",
            recurrence="none",
            timezone="Asia/Kolkata",
            channels=["local", "whatsapp"],
            rawPrompt="Submit capstone Dec 1 at 10 AM",
        )

        first_id = persist_confirmed_reminder_to_db(
            draft=draft,
            user_phone_number=phone,
            channels_dispatched=[],
            user_id=user_id,
            reminder_id=reminder_id,
            session=db,
        )
        assert first_id == reminder_id

        # Second confirmation / sync pass should NOT duplicate channels
        second_id = persist_confirmed_reminder_to_db(
            draft=draft,
            user_phone_number=phone,
            channels_dispatched=["whatsapp"],
            user_id=user_id,
            reminder_id=reminder_id,
            session=db,
        )
        assert second_id == reminder_id

        channels = (
            db.query(ReminderChannel)
            .filter_by(reminder_id=reminder_id)
            .order_by(ReminderChannel.channel)
            .all()
        )
        assert len(channels) == 2
        by_name = {c.channel: c for c in channels}
        assert by_name["local"].status == "PENDING"
        assert by_name["whatsapp"].status == "DISPATCHED"
    finally:
        db.close()


def test_recurring_whatsapp_scheduler_advances_due_date_and_queues_next():
    """Verify recurring daily/weekly reminders advance after dispatch and accept message_sid."""
    init_db()
    db: Session = next(get_db_session())
    try:
        user_id = str(uuid.uuid4())
        reminder_id = str(uuid.uuid4())
        phone = f"+1666{uuid.uuid4().int % 10000000:07d}"
        user = User(
            id=user_id,
            email=f"rec_{user_id[:8]}@example.com",
            password_hash=hash_password("ValidPass123!"),
            full_name="Recurring Tester",
            phone_number=phone,
            phone_verified=True,
            timezone="UTC",
        )
        db.add(user)
        db.commit()

        due_d = date(2026, 11, 20)
        due_utc = datetime(2026, 11, 20, 9, 0, tzinfo=timezone.utc)
        reminder = Reminder(
            id=reminder_id,
            user_id=user_id,
            title="Daily Standup",
            description="Join meeting link",
            due_date=due_d,
            due_hour=9,
            due_minute=0,
            timezone="UTC",
            due_timestamp_utc=due_utc,
            priority="high",
            recurrence="daily",
            status="CONFIRMED",
            raw_prompt="Daily standup at 9 AM",
        )
        db.add(reminder)
        db.flush()
        db.add(
            ReminderChannel(
                reminder_id=reminder_id,
                channel="whatsapp",
                status="PENDING",
            )
        )
        db.commit()

        mock_wa = MagicMock()
        mock_wa.send_reminder_sync.return_value = {
            "success": True,
            "message_sid": "SM_RECUR_TEST_999",
        }

        scheduler = ReminderScheduler(whatsapp_service=mock_wa)
        now_dt = datetime(2026, 11, 20, 9, 5, tzinfo=timezone.utc)
        results = scheduler.process_due_reminders(db, current_dt=now_dt)

        matching = [r for r in results if r["reminder_id"] == reminder_id]
        assert len(matching) == 1
        assert matching[0]["status"] == "DISPATCHED"
        assert matching[0]["sid"] == "SM_RECUR_TEST_999"

        db.refresh(reminder)
        assert reminder.due_date == date(2026, 11, 21)
        assert reminder.due_timestamp_utc is not None
        assert reminder.due_timestamp_utc.replace(tzinfo=timezone.utc) > now_dt

        all_wa_channels = (
            db.query(ReminderChannel)
            .filter_by(reminder_id=reminder_id, channel="whatsapp")
            .all()
        )
        statuses = sorted(c.status for c in all_wa_channels)
        assert statuses == ["DISPATCHED", "PENDING"]
    finally:
        db.close()


def test_same_second_refresh_tokens_produce_distinct_jti():
    """Verify same-second JWT issuance includes distinct jti claims to avoid rotation collision."""
    t1 = create_refresh_token(user_id="u-jti-1", phone_number="+15550001111")
    t2 = create_refresh_token(user_id="u-jti-1", phone_number="+15550001111")
    a1 = create_access_token(user_id="u-jti-1", phone_number="+15550001111")
    a2 = create_access_token(user_id="u-jti-1", phone_number="+15550001111")

    assert t1 != t2
    assert a1 != a2
    assert decode_refresh_token(t1)["jti"] != decode_refresh_token(t2)["jti"]
    assert decode_access_token(a1)["jti"] != decode_access_token(a2)["jti"]


def test_plan_endpoint_resolves_authenticated_user_timezone(monkeypatch):
    """Verify /agent/reminders/plan falls back to user profile timezone when omitted."""
    init_db()
    db: Session = next(get_db_session())
    try:
        user_id = str(uuid.uuid4())
        phone = f"+1444{uuid.uuid4().int % 10000000:07d}"
        user = User(
            id=user_id,
            email=f"tz_{user_id[:8]}@example.com",
            password_hash=hash_password("ValidPass123!"),
            full_name="London User",
            phone_number=phone,
            phone_verified=True,
            timezone="Europe/London",
        )
        db.add(user)
        db.commit()
        token = create_access_token(user_id=user.id, phone_number=phone, name="London User")
    finally:
        db.close()

    captured = {}

    async def fake_process_plan(req):
        captured["timezone"] = req.timezone
        from agent.models.reminder_schema import ReminderPlanResponse

        return ReminderPlanResponse(
            success=True,
            raw_prompt=req.prompt,
            clarification_needed="Which time should I schedule this reminder for?",
            message="Which time should I schedule this reminder for?",
            reminders=[],
        )

    from agent import app as app_module

    monkeypatch.setattr(app_module.agent, "process_plan_async", fake_process_plan)

    client = TestClient(app)
    resp = client.post(
        "/agent/reminders/plan",
        json={"prompt": "Remind me tomorrow to send my resume"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert captured["timezone"] == "Europe/London"
    assert "clarification_needed" in body
    assert body["clarification_needed"] is not None
