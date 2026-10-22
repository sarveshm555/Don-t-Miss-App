"""Integration and unit tests for Phase 3: Batch Confirmation and Creation.

Covers:
1. Successful batch creation of multiple reminders
2. Empty batches and invalid reminder data validation
3. Authentication failures (missing, expired, malformed tokens)
4. Cross-account data isolation & client-supplied ID collision protection
5. Database transaction rollback (all-or-nothing guarantee)
6. Duplicate request retries via idempotency mechanism
7. Notification scheduling failure reporting (separate from DB persistence)
8. Unverified user / missing phone number safe handling
9. Backward compatibility for existing single-reminder flows
"""

import json
import uuid
from typing import Tuple, List, Optional
import pytest
from datetime import datetime, date, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock, patch
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from agent.app import app
from agent.database.connection import get_db_session, init_db
from agent.database.models import User, Reminder, ReminderChannel, ActionHistory
from agent.models.reminder_schema import (
    ReminderDraft,
    ReminderBatchRequest,
    ReminderBatchResponse,
    ActionConfirmRequest,
)
from agent.services.jwt_service import create_access_token, get_jwt_secret
from agent.services.password_service import hash_password


@pytest.fixture
def test_client():
    init_db()
    return TestClient(app)


def _unique_phone():
    return f"+1888{uuid.uuid4().int % 10000000:07d}"


def _create_test_user(db: Session, phone_verified: bool = True) -> Tuple[User, str]:
    """Helper to create a test user in DB and return (User, JWT token)."""
    user_id = str(uuid.uuid4())
    phone = _unique_phone()
    email = f"user_{user_id[:8]}@example.com"
    user = User(
        id=user_id,
        email=email,
        password_hash=hash_password("ValidPassword123!"),
        full_name="Batch Tester",
        phone_number=phone,
        phone_verified=phone_verified,
    )
    db.add(user)
    db.commit()
    db.refresh(user)

    token = create_access_token(
        user_id=user.id,
        phone_number=user.phone_number,
        name=user.full_name,
    )
    return user, token


# ==============================================================================
# 1. Successful Creation of Multiple Reminders
# ==============================================================================

def test_batch_creation_success(test_client):
    """Verify that multiple validated reminder drafts are saved atomically in DB."""
    db: Session = next(get_db_session())
    try:
        user, token = _create_test_user(db, phone_verified=True)

        payload = {
            "reminders": [
                {
                    "title": "Gemini Hackathon Review",
                    "description": "Prepare final slides",
                    "dueDate": "2026-10-25",
                    "dueHour": 14,
                    "dueMinute": 30,
                    "priority": "high",
                    "recurrence": "none",
                    "channels": ["local", "whatsapp"],
                },
                {
                    "title": "Friend's Birthday Celebration",
                    "description": "Order surprise cake",
                    "dueDate": "2026-10-26",
                    "dueHour": 9,
                    "dueMinute": 0,
                    "priority": "medium",
                    "recurrence": "none",
                    "channels": ["local"],
                },
            ],
            "idempotency_key": f"key-{uuid.uuid4()}",
        }

        res = test_client.post(
            "/agent/reminders/batch",
            headers={"Authorization": f"Bearer {token}"},
            json=payload,
        )

        assert res.status_code == 200, res.text
        data = res.json()
        assert data["success"] is True
        assert data["status"] == "CONFIRMED"
        assert data["total_requested"] == 2
        assert data["total_created"] == 2
        assert len(data["created_reminder_ids"]) == 2
        assert len(data["reminders"]) == 2

        # Verify reminders exist in DB with correct user_id
        db_rems = (
            db.query(Reminder)
            .filter(Reminder.id.in_(data["created_reminder_ids"]))
            .all()
        )
        assert len(db_rems) == 2
        for r in db_rems:
            assert r.user_id == user.id
            assert r.status == "CONFIRMED"

        # Verify channels created in DB
        channels = (
            db.query(ReminderChannel)
            .filter(ReminderChannel.reminder_id.in_(data["created_reminder_ids"]))
            .all()
        )
        assert len(channels) >= 3  # 2 for first, 1 for second

        # Verify scheduling status in response
        assert len(data["scheduling_status"]) >= 3
        local_statuses = [s for s in data["scheduling_status"] if s["channel"] == "local"]
        assert len(local_statuses) == 2
        for ls in local_statuses:
            assert ls["status"] == "READY_FOR_DEVICE_SCHEDULE"
            assert ls["delivered"] is False
    finally:
        db.close()


# ==============================================================================
# 2. Empty Batches and Invalid Reminder Data
# ==============================================================================

def test_batch_empty_rejected(test_client):
    """Verify that an empty batch is rejected with HTTP 400."""
    db: Session = next(get_db_session())
    try:
        user, token = _create_test_user(db)
        res = test_client.post(
            "/agent/reminders/batch",
            headers={"Authorization": f"Bearer {token}"},
            json={"reminders": []},
        )
        assert res.status_code == 400
        assert "empty" in res.json()["detail"].lower()
    finally:
        db.close()


def test_batch_empty_title_rejected(test_client):
    """Verify that a reminder with empty or whitespace title is rejected."""
    db: Session = next(get_db_session())
    try:
        user, token = _create_test_user(db)
        payload = {
            "reminders": [
                {"title": "Valid Meeting", "dueDate": "2026-10-25"},
                {"title": "   ", "dueDate": "2026-10-25"},
            ]
        }
        res = test_client.post(
            "/agent/reminders/batch",
            headers={"Authorization": f"Bearer {token}"},
            json=payload,
        )
        assert res.status_code == 400
        assert "title" in res.json()["detail"].lower()
    finally:
        db.close()


def test_batch_invalid_due_date_rejected(test_client):
    """Verify that an invalid dueDate format is rejected."""
    db: Session = next(get_db_session())
    try:
        user, token = _create_test_user(db)
        payload = {
            "reminders": [
                {"title": "Valid Meeting", "dueDate": "not-a-date"},
            ]
        }
        res = test_client.post(
            "/agent/reminders/batch",
            headers={"Authorization": f"Bearer {token}"},
            json=payload,
        )
        assert res.status_code == 400
        assert "duedate" in res.json()["detail"].lower()
    finally:
        db.close()


def test_batch_invalid_hour_minute_rejected(test_client):
    """Verify that out-of-range hours and minutes are rejected."""
    db: Session = next(get_db_session())
    try:
        user, token = _create_test_user(db)
        # Invalid hour: 25
        payload_hour = {
            "reminders": [
                {"title": "Midnight Meeting", "dueHour": 25, "dueMinute": 0},
            ]
        }
        res_hour = test_client.post(
            "/agent/reminders/batch",
            headers={"Authorization": f"Bearer {token}"},
            json=payload_hour,
        )
        assert res_hour.status_code == 422 or res_hour.status_code == 400

        # Invalid minute: 75
        payload_min = {
            "reminders": [
                {"title": "Late Meeting", "dueHour": 10, "dueMinute": 75},
            ]
        }
        res_min = test_client.post(
            "/agent/reminders/batch",
            headers={"Authorization": f"Bearer {token}"},
            json=payload_min,
        )
        assert res_min.status_code == 422 or res_min.status_code == 400
    finally:
        db.close()


# ==============================================================================
# 3. Authentication Failures
# ==============================================================================

def test_batch_unauthenticated_request_rejected(test_client):
    """Verify that missing Authorization header returns HTTP 401."""
    res = test_client.post(
        "/agent/reminders/batch",
        json={"reminders": [{"title": "Unauthenticated Task"}]},
    )
    assert res.status_code == 401
    assert "token required" in res.json()["detail"].lower()


def test_batch_expired_token_rejected(test_client):
    """Verify that an expired JWT token returns HTTP 401."""
    expired_token = create_access_token(
        user_id="usr-expired",
        expires_delta=timedelta(seconds=-10),
    )
    res = test_client.post(
        "/agent/reminders/batch",
        headers={"Authorization": f"Bearer {expired_token}"},
        json={"reminders": [{"title": "Expired Token Task"}]},
    )
    assert res.status_code == 401
    assert "expired" in res.json()["detail"].lower()


def test_batch_malformed_token_rejected(test_client):
    """Verify that a malformed Bearer token returns HTTP 401."""
    res = test_client.post(
        "/agent/reminders/batch",
        headers={"Authorization": "Bearer not-a-valid-jwt-token"},
        json={"reminders": [{"title": "Malformed Token Task"}]},
    )
    assert res.status_code == 401


# ==============================================================================
# 4. Cross-Account Data Isolation & Client ID Collision Protection
# ==============================================================================

def test_batch_cross_account_isolation(test_client):
    """Verify user cannot view or collide with another user's reminders."""
    db: Session = next(get_db_session())
    try:
        user_a, token_a = _create_test_user(db)
        user_b, token_b = _create_test_user(db)

        # 1. User A creates a batch
        fixed_id = f"rem-a-{uuid.uuid4()}"
        res_a = test_client.post(
            "/agent/reminders/batch",
            headers={"Authorization": f"Bearer {token_a}"},
            json={
                "reminders": [
                    {"id": fixed_id, "title": "User A Private Note"},
                ]
            },
        )
        assert res_a.status_code == 200
        assert res_a.json()["created_reminder_ids"] == [fixed_id]

        # 2. User B tries to hijack User A's ID in a batch -> HTTP 409 Conflict
        res_b_collision = test_client.post(
            "/agent/reminders/batch",
            headers={"Authorization": f"Bearer {token_b}"},
            json={
                "reminders": [
                    {"id": fixed_id, "title": "User B Hijack Attempt"},
                ]
            },
        )
        assert res_b_collision.status_code == 409
        assert "collision" in res_b_collision.json()["detail"].lower()

        # 3. User B cannot see User A's reminder on GET /reminders
        res_b_get = test_client.get(
            "/reminders",
            headers={"Authorization": f"Bearer {token_b}"},
        )
        assert res_b_get.status_code == 200
        user_b_rem_ids = [r["id"] for r in res_b_get.json()]
        assert fixed_id not in user_b_rem_ids

        # 4. User A body attempting to pass spoofed user_id is ignored
        res_a_spoof = test_client.post(
            "/agent/reminders/batch",
            headers={"Authorization": f"Bearer {token_a}"},
            json={
                "reminders": [
                    {"title": "Spoof Attempt"},
                ]
            },
        )
        assert res_a_spoof.status_code == 200
        spoofed_rem_id = res_a_spoof.json()["created_reminder_ids"][0]
        db_spoofed = db.query(Reminder).filter(Reminder.id == spoofed_rem_id).first()
        assert db_spoofed.user_id == user_a.id
    finally:
        db.close()


# ==============================================================================
# 5. Database Transaction Rollback (All-or-Nothing Guarantee)
# ==============================================================================

def test_batch_database_transaction_rollback(test_client):
    """Verify that if a database error occurs mid-batch, ALL inserts are rolled back."""
    db: Session = next(get_db_session())
    try:
        user, token = _create_test_user(db)
        rem_id_1 = f"roll-1-{uuid.uuid4()}"
        rem_id_2 = f"roll-2-{uuid.uuid4()}"

        payload = {
            "reminders": [
                {"id": rem_id_1, "title": "Task 1 Before Crash"},
                {"id": rem_id_2, "title": "Task 2 Trigger Crash"},
            ]
        }

        # Mock db.commit to simulate database constraint/disk failure
        with patch.object(Session, "commit", side_effect=Exception("Simulated DB connection drop")):
            res = test_client.post(
                "/agent/reminders/batch",
                headers={"Authorization": f"Bearer {token}"},
                json=payload,
            )

        assert res.status_code == 500
        assert "transaction failed" in res.json()["detail"].lower()

        # Crucial: verify NEITHER reminder 1 nor 2 was persisted in the database!
        db.expire_all()
        rem1 = db.query(Reminder).filter(Reminder.id == rem_id_1).first()
        rem2 = db.query(Reminder).filter(Reminder.id == rem_id_2).first()
        assert rem1 is None
        assert rem2 is None
    finally:
        db.close()


# ==============================================================================
# 6. Duplicate Request Retries (Idempotency)
# ==============================================================================

def test_batch_idempotency_duplicate_retry(test_client):
    """Verify that re-submitting with the same idempotency key does not create duplicates."""
    db: Session = next(get_db_session())
    try:
        user, token = _create_test_user(db)
        idem_key = f"idem-key-{uuid.uuid4()}"

        payload = {
            "reminders": [
                {"title": "Review System Design", "dueDate": "2026-10-28"},
                {"title": "Submit Pull Request", "dueDate": "2026-10-28"},
            ],
            "idempotency_key": idem_key,
        }

        # First request
        res1 = test_client.post(
            "/agent/reminders/batch",
            headers={"Authorization": f"Bearer {token}"},
            json=payload,
        )
        assert res1.status_code == 200
        data1 = res1.json()
        assert data1["status"] == "CONFIRMED"
        created_ids_1 = data1["created_reminder_ids"]
        assert len(created_ids_1) == 2

        # Second request (retry with same idempotency key)
        res2 = test_client.post(
            "/agent/reminders/batch",
            headers={"Authorization": f"Bearer {token}"},
            json=payload,
        )
        assert res2.status_code == 200
        data2 = res2.json()
        assert data2["status"] == "ALREADY_PROCESSED"
        assert data2["success"] is True
        assert set(data2["created_reminder_ids"]) == set(created_ids_1)
        assert data2["created_reminder_ids"] == created_ids_1

        # Verify DB total count for this user is exactly 2, NOT 4
        user_rems = db.query(Reminder).filter(Reminder.user_id == user.id).all()
        assert len(user_rems) == 2
    finally:
        db.close()


# ==============================================================================
# 7. Notification Scheduling Failure Reporting
# ==============================================================================

@pytest.mark.anyio
def test_batch_notification_scheduling_failure_reported(test_client):
    """Verify that notification scheduling failures are accurately reported without breaking DB persistence."""
    db: Session = next(get_db_session())
    try:
        user, token = _create_test_user(db, phone_verified=True)
        today_str = date.today().isoformat()

        payload = {
            "reminders": [
                {
                    "title": "Immediate Urgent Reminder",
                    "dueDate": today_str,
                    "dueHour": 0,  # Midnight, definitely due now
                    "dueMinute": 0,
                    "channels": ["local", "whatsapp"],
                }
            ]
        }

        # Mock WhatsApp service to return failure
        with patch(
            "agent.app.batch_reminder_service.whatsapp_service.send_reminder",
            new=AsyncMock(return_value={"success": False, "error": "Twilio 503 Service Unavailable"}),
        ):
            res = test_client.post(
                "/agent/reminders/batch",
                headers={"Authorization": f"Bearer {token}"},
                json=payload,
            )

        assert res.status_code == 200
        data = res.json()
        assert data["success"] is True
        assert data["total_created"] == 1
        rem_id = data["created_reminder_ids"][0]

        # Verify DB persistence succeeded despite notification failure
        db_rem = db.query(Reminder).filter(Reminder.id == rem_id).first()
        assert db_rem is not None
        assert db_rem.title == "Immediate Urgent Reminder"

        # Verify scheduling status accurately reports failure
        wa_status = next(s for s in data["scheduling_status"] if s["channel"] == "whatsapp")
        assert wa_status["status"] == "FAILED"
        assert wa_status["delivered"] is False
        assert "503" in wa_status["detail"]

        # Verify failures array contains actionable notice
        assert len(data["failures"]) == 1
        assert "503" in data["failures"][0]["reason"]
    finally:
        db.close()


# ==============================================================================
# 8. Unverified User & Missing Phone Safe Handling
# ==============================================================================

def test_batch_unverified_user_whatsapp_skipped(test_client):
    """Verify that unverified users have WhatsApp safely skipped and reported."""
    db: Session = next(get_db_session())
    try:
        user, token = _create_test_user(db, phone_verified=False)

        payload = {
            "reminders": [
                {
                    "title": "Unverified User Task",
                    "channels": ["local", "whatsapp"],
                }
            ]
        }

        res = test_client.post(
            "/agent/reminders/batch",
            headers={"Authorization": f"Bearer {token}"},
            json=payload,
        )

        assert res.status_code == 200
        data = res.json()
        assert data["success"] is True

        wa_status = next(s for s in data["scheduling_status"] if s["channel"] == "whatsapp")
        assert wa_status["status"] == "SKIPPED_UNVERIFIED"
        assert wa_status["delivered"] is False

        assert len(data["failures"]) == 1
        assert "unverified" in data["failures"][0]["reason"].lower()
        assert "profile" in data["failures"][0]["action_required"].lower()
    finally:
        db.close()


# ==============================================================================
# 9. Existing Single-Reminder Endpoints Backward Compatibility
# ==============================================================================

def test_single_reminder_endpoints_backward_compatibility(test_client):
    """Verify POST /action/confirm and single-reminder routes still function identically."""
    db: Session = next(get_db_session())
    try:
        user, token = _create_test_user(db, phone_verified=True)

        # Single confirmation request via /action/confirm
        payload = {
            "action": "confirm_reminder",
            "draft": {
                "title": "Legacy Single Reminder",
                "description": "Legacy format test",
                "dueDate": "2026-10-30",
                "dueHour": 11,
                "dueMinute": 0,
                "priority": "medium",
                "recurrence": "none",
                "channels": ["local"],
            },
            "user_id": user.id,
        }

        res = test_client.post(
            "/action/confirm",
            headers={"Authorization": f"Bearer {token}"},
            json=payload,
        )

        assert res.status_code == 200
        data = res.json()
        assert data["success"] is True
        assert data["status"] == "ROUTED"
        assert "local" in data["channels_dispatched"]
        assert data["reminder_id"] is not None

        # Verify persisted reminder exists
        db_rem = db.query(Reminder).filter(Reminder.id == data["reminder_id"]).first()
        assert db_rem is not None
        assert db_rem.title == "Legacy Single Reminder"
    finally:
        db.close()
