import uuid
from datetime import timedelta
import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from unittest.mock import patch
from agent.app import app
from agent.database.connection import get_db_session, init_db
from agent.database.models import User
from agent.services.jwt_service import (
    create_access_token,
    create_refresh_token,
    decode_access_token,
    decode_refresh_token,
)
from agent.services.password_service import hash_password


@pytest.fixture
def test_client():
    init_db()
    with patch("agent.services.reminder_scheduler.ReminderScheduler.start"):
        with TestClient(app) as client:
            yield client


def _unique_phone():
    return f"+1888{uuid.uuid4().int % 10000000:07d}"


def _create_test_user(db: Session, phone_verified: bool = True):
    user_id = str(uuid.uuid4())
    phone = _unique_phone()
    email = f"user_{user_id[:8]}@example.com"
    user = User(
        id=user_id,
        email=email,
        password_hash=hash_password("securepassword123"),
        full_name="Alex River",
        phone_number=phone,
        phone_verified=phone_verified,
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


def test_signup_returns_access_and_refresh_tokens(test_client):
    phone = _unique_phone()
    payload = {
        "name": "Jordan Smith",
        "phone_number": phone,
        "password": "Password123!",
    }
    response = test_client.post("/auth/signup", json=payload)
    assert response.status_code == 200
    data = response.json()
    assert data["success"] is True
    assert "token" in data and data["token"] is not None
    assert "refresh_token" in data and data["refresh_token"] is not None

    access_claims = decode_access_token(data["token"])
    assert access_claims["type"] == "access"
    assert access_claims["name"] == "Jordan Smith"

    refresh_claims = decode_refresh_token(data["refresh_token"])
    assert refresh_claims["type"] == "refresh"
    assert refresh_claims["name"] == "Jordan Smith"


def test_signin_returns_access_and_refresh_tokens(test_client):
    db: Session = next(get_db_session())
    try:
        user = _create_test_user(db, phone_verified=True)
        payload = {
            "phone_number": user.phone_number,
            "password": "securepassword123",
        }
        response = test_client.post("/auth/signin", json=payload)
        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True
        assert data["token"] is not None
        assert data["refresh_token"] is not None

        access_claims = decode_access_token(data["token"])
        assert access_claims["sub"] == user.id
        assert access_claims["type"] == "access"

        refresh_claims = decode_refresh_token(data["refresh_token"])
        assert refresh_claims["sub"] == user.id
        assert refresh_claims["type"] == "refresh"
    finally:
        db.close()


def test_refresh_endpoint_success_with_json_body(test_client):
    db: Session = next(get_db_session())
    try:
        user = _create_test_user(db, phone_verified=True)
        refresh_token = create_refresh_token(
            user_id=user.id,
            phone_number=user.phone_number,
            name=user.full_name,
        )
        response = test_client.post("/auth/refresh", json={"refresh_token": refresh_token})
        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True
        assert "token" in data and len(data["token"]) > 10
        assert "refresh_token" in data and len(data["refresh_token"]) > 10

        new_access_claims = decode_access_token(data["token"])
        assert new_access_claims["sub"] == user.id
        assert new_access_claims["type"] == "access"

        new_refresh_claims = decode_refresh_token(data["refresh_token"])
        assert new_refresh_claims["sub"] == user.id
        assert new_refresh_claims["type"] == "refresh"
    finally:
        db.close()


def test_refresh_endpoint_success_with_bearer_header(test_client):
    db: Session = next(get_db_session())
    try:
        user = _create_test_user(db, phone_verified=True)
        refresh_token = create_refresh_token(
            user_id=user.id,
            phone_number=user.phone_number,
            name=user.full_name,
        )
        response = test_client.post("/auth/refresh", headers={"Authorization": f"Bearer {refresh_token}"})
        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True
        assert data["token"] is not None
        assert data["refresh_token"] is not None
    finally:
        db.close()


def test_refresh_endpoint_rejects_missing_token(test_client):
    response = test_client.post("/auth/refresh", json={})
    assert response.status_code == 400
    data = response.json()
    assert data["success"] is False
    assert "required" in data["message"].lower()


def test_refresh_endpoint_rejects_access_token(test_client):
    access_token = create_access_token(user_id="user-123")
    response = test_client.post("/auth/refresh", json={"refresh_token": access_token})
    assert response.status_code == 401
    data = response.json()
    assert data["success"] is False
    assert "invalid refresh token" in data["message"].lower()


def test_protected_endpoint_rejects_refresh_token(test_client):
    refresh_token = create_refresh_token(user_id="user-123")
    response = test_client.get("/auth/me", headers={"Authorization": f"Bearer {refresh_token}"})
    assert response.status_code == 401
    assert "refresh token cannot be used as an access token" in response.json()["detail"].lower()


def test_refresh_endpoint_rejects_expired_refresh_token(test_client):
    expired_token = create_refresh_token(
        user_id="user-123",
        expires_delta=timedelta(seconds=-10),
    )
    response = test_client.post("/auth/refresh", json={"refresh_token": expired_token})
    assert response.status_code == 401
    data = response.json()
    assert data["success"] is False
    assert "expired" in data["message"].lower()


def test_refresh_endpoint_rejects_nonexistent_user(test_client):
    refresh_token = create_refresh_token(user_id="user-does-not-exist")
    response = test_client.post("/auth/refresh", json={"refresh_token": refresh_token})
    assert response.status_code == 401
    data = response.json()
    assert data["success"] is False
    assert "user not found" in data["message"].lower()
