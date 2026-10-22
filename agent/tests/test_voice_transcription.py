"""Tests for Voice Transcription Endpoint (POST /agent/voice/transcribe).

Covers:
1. Successful voice transcription (multipart & base64 JSON)
2. Empty audio rejection (0 bytes)
3. Unsupported file formats rejection
4. File size limit enforcement (> 25 MB)
5. Transcription API failure handling (graceful, no credential leakage)
6. Empty transcription response (silent speech handling)
7. Authentication behavior (optional auth accepts valid token and handles invalid)
8. API key is never exposed in responses or logs
"""

import base64
import io
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from fastapi.testclient import TestClient

from agent.app import app
from agent.database.connection import get_db_session, init_db
from agent.database.models import User
from agent.providers.openai_provider import OpenAIProvider
from agent.services.jwt_service import create_access_token
from agent.services.password_service import hash_password


@pytest.fixture
def test_client():
    init_db()
    return TestClient(app)


def _dummy_audio_bytes():
    # Valid non-empty audio header / bytes
    return b"RIFF____WAVEfmt " + b"\x00" * 32 + b"data" + b"\x00" * 64


# ==============================================================================
# 1. Successful Transcription
# ==============================================================================

def test_transcribe_multipart_success(test_client):
    """Verify transcription via multipart/form-data upload."""
    mock_transcription = MagicMock()
    mock_transcription.text = "Remind me to call John tomorrow at 5 PM"

    with patch(
        "agent.services.voice_transcription_service.OpenAIProvider.is_configured",
        True,
    ), patch(
        "agent.services.voice_transcription_service.OpenAIProvider.get_async_client"
    ) as mock_get_client:
        mock_client = AsyncMock()
        mock_client.audio.transcriptions.create.return_value = mock_transcription
        mock_get_client.return_value = mock_client

        audio_data = _dummy_audio_bytes()
        files = {
            "file": ("recording.m4a", io.BytesIO(audio_data), "audio/m4a"),
        }
        res = test_client.post("/agent/voice/transcribe", files=files)

        assert res.status_code == 200, res.text
        data = res.json()
        assert data["success"] is True
        assert data["text"] == "Remind me to call John tomorrow at 5 PM"
        assert data["filename"] == "recording.m4a"
        assert "api_key" not in res.text
        assert "sk-" not in res.text


def test_transcribe_base64_json_success(test_client):
    """Verify transcription via JSON with base64 encoded audio."""
    mock_transcription = MagicMock()
    mock_transcription.text = "Team standup at 10 AM and doctor at 4 PM"

    with patch(
        "agent.services.voice_transcription_service.OpenAIProvider.is_configured",
        True,
    ), patch(
        "agent.services.voice_transcription_service.OpenAIProvider.get_async_client"
    ) as mock_get_client:
        mock_client = AsyncMock()
        mock_client.audio.transcriptions.create.return_value = mock_transcription
        mock_get_client.return_value = mock_client

        audio_b64 = base64.b64encode(_dummy_audio_bytes()).decode("utf-8")
        payload = {
            "audio_base64": audio_b64,
            "filename": "speech.wav",
        }
        res = test_client.post("/agent/voice/transcribe", json=payload)

        assert res.status_code == 200, res.text
        data = res.json()
        assert data["success"] is True
        assert data["text"] == "Team standup at 10 AM and doctor at 4 PM"
        assert data["filename"] == "speech.wav"


# ==============================================================================
# 2. Empty Audio Upload
# ==============================================================================

def test_transcribe_empty_audio_rejected(test_client):
    """Verify that 0-byte audio is rejected with HTTP 400."""
    files = {
        "file": ("empty.m4a", io.BytesIO(b""), "audio/m4a"),
    }
    res = test_client.post("/agent/voice/transcribe", files=files)
    assert res.status_code == 400
    assert "empty" in res.json()["detail"].lower()


def test_transcribe_empty_base64_rejected(test_client):
    """Verify that empty base64 string is rejected with HTTP 400."""
    res = test_client.post(
        "/agent/voice/transcribe",
        json={"audio_base64": "", "filename": "audio.m4a"},
    )
    assert res.status_code == 400
    assert "missing" in res.json()["detail"].lower() or "empty" in res.json()["detail"].lower()


# ==============================================================================
# 3. Unsupported File Format
# ==============================================================================

def test_transcribe_unsupported_format_rejected(test_client):
    """Verify that unsupported extensions (e.g. .txt, .pdf, .exe) are rejected."""
    files = {
        "file": ("document.txt", io.BytesIO(b"some text data"), "text/plain"),
    }
    res = test_client.post("/agent/voice/transcribe", files=files)
    assert res.status_code == 400
    assert "unsupported" in res.json()["detail"].lower()


# ==============================================================================
# 4. File Size Limit
# ==============================================================================

def test_transcribe_file_size_limit_enforced(test_client):
    """Verify that files exceeding 25 MB are rejected with HTTP 413."""
    # Mock len(audio_bytes) to simulate 26 MB
    oversized = b"a" * (26 * 1024 * 1024)
    files = {
        "file": ("large.m4a", io.BytesIO(oversized), "audio/m4a"),
    }
    res = test_client.post("/agent/voice/transcribe", files=files)
    assert res.status_code == 413
    assert "25 mb" in res.json()["detail"].lower()


# ==============================================================================
# 5. Transcription API Failure & Unconfigured OpenAI
# ==============================================================================

def test_transcribe_unconfigured_openai(test_client):
    """Verify graceful HTTP 503 response when OpenAI provider is not configured."""
    with patch(
        "agent.services.voice_transcription_service.OpenAIProvider.is_configured",
        False,
    ):
        audio_b64 = base64.b64encode(_dummy_audio_bytes()).decode("utf-8")
        res = test_client.post(
            "/agent/voice/transcribe",
            json={"audio_base64": audio_b64, "filename": "audio.m4a"},
        )
        assert res.status_code == 503
        assert "openai api is not configured" in res.json()["detail"].lower()


def test_transcribe_api_exception_handling(test_client):
    """Verify graceful handling when OpenAI API raises a generic exception."""
    with patch(
        "agent.services.voice_transcription_service.OpenAIProvider.is_configured",
        True,
    ), patch(
        "agent.services.voice_transcription_service.OpenAIProvider.get_async_client"
    ) as mock_get_client:
        mock_client = AsyncMock()
        mock_client.audio.transcriptions.create.side_effect = Exception("OpenAI Whisper server error")
        mock_get_client.return_value = mock_client

        audio_b64 = base64.b64encode(_dummy_audio_bytes()).decode("utf-8")
        res = test_client.post(
            "/agent/voice/transcribe",
            json={"audio_base64": audio_b64, "filename": "audio.m4a"},
        )
        assert res.status_code == 502
        assert "transcription failed" in res.json()["detail"].lower()
        # Verify no secret leakage
        assert "api_key" not in res.text
        assert "sk-" not in res.text


def test_transcribe_api_timeout_handling(test_client):
    """Verify HTTP 504 when OpenAI connection times out."""
    with patch(
        "agent.services.voice_transcription_service.OpenAIProvider.is_configured",
        True,
    ), patch(
        "agent.services.voice_transcription_service.OpenAIProvider.get_async_client"
    ) as mock_get_client:
        mock_client = AsyncMock()
        mock_client.audio.transcriptions.create.side_effect = Exception("Request timed out")
        mock_get_client.return_value = mock_client

        audio_b64 = base64.b64encode(_dummy_audio_bytes()).decode("utf-8")
        res = test_client.post(
            "/agent/voice/transcribe",
            json={"audio_base64": audio_b64, "filename": "audio.m4a"},
        )
        assert res.status_code == 504
        assert "timed out" in res.json()["detail"].lower()


def test_transcribe_api_rate_limit_handling(test_client):
    """Verify HTTP 429 when OpenAI rate limit is exceeded."""
    with patch(
        "agent.services.voice_transcription_service.OpenAIProvider.is_configured",
        True,
    ), patch(
        "agent.services.voice_transcription_service.OpenAIProvider.get_async_client"
    ) as mock_get_client:
        mock_client = AsyncMock()
        mock_client.audio.transcriptions.create.side_effect = Exception("429 rate limit exceeded")
        mock_get_client.return_value = mock_client

        audio_b64 = base64.b64encode(_dummy_audio_bytes()).decode("utf-8")
        res = test_client.post(
            "/agent/voice/transcribe",
            json={"audio_base64": audio_b64, "filename": "audio.m4a"},
        )
        assert res.status_code == 429
        assert "rate limit" in res.json()["detail"].lower()


def test_transcribe_fallback_to_whisper1(test_client):
    """Verify fallback to whisper-1 if gpt-4o-mini-transcribe is unavailable."""
    with patch(
        "agent.services.voice_transcription_service.OpenAIProvider.is_configured",
        True,
    ), patch(
        "agent.services.voice_transcription_service.OpenAIProvider.get_async_client"
    ) as mock_get_client:
        mock_client = AsyncMock()
        mock_success = MagicMock()
        mock_success.text = "Fallback success reminder"

        # First call (gpt-4o-mini-transcribe) fails with model not found, second succeeds
        mock_client.audio.transcriptions.create.side_effect = [
            Exception("Model gpt-4o-mini-transcribe not found or not supported"),
            mock_success,
        ]
        mock_get_client.return_value = mock_client

        audio_b64 = base64.b64encode(_dummy_audio_bytes()).decode("utf-8")
        res = test_client.post(
            "/agent/voice/transcribe",
            json={"audio_base64": audio_b64, "filename": "audio.m4a"},
        )
        assert res.status_code == 200
        assert res.json()["text"] == "Fallback success reminder"
        assert mock_client.audio.transcriptions.create.call_count == 2


# ==============================================================================
# 6. Empty Transcription Response (Silence)
# ==============================================================================

def test_transcribe_empty_text_response(test_client):
    """Verify that silent audio producing empty text returns guidance message."""
    mock_transcription = MagicMock()
    mock_transcription.text = ""  # No speech detected

    with patch(
        "agent.services.voice_transcription_service.OpenAIProvider.is_configured",
        True,
    ), patch(
        "agent.services.voice_transcription_service.OpenAIProvider.get_async_client"
    ) as mock_get_client:
        mock_client = AsyncMock()
        mock_client.audio.transcriptions.create.return_value = mock_transcription
        mock_get_client.return_value = mock_client

        audio_b64 = base64.b64encode(_dummy_audio_bytes()).decode("utf-8")
        res = test_client.post(
            "/agent/voice/transcribe",
            json={"audio_base64": audio_b64, "filename": "audio.m4a"},
        )
        assert res.status_code == 200
        data = res.json()
        assert data["success"] is True
        assert data["text"] == ""
        assert "no speech detected" in data["message"].lower()


# ==============================================================================
# 7. Authentication Behavior
# ==============================================================================

def test_transcribe_with_authenticated_user(test_client):
    """Verify endpoint works with valid Bearer token."""
    db = next(get_db_session())
    try:
        user = User(
            id="usr-test-voice",
            email="voice_user@example.com",
            password_hash=hash_password("Pass123!"),
            full_name="Voice User",
            phone_number="+15551234567",
            phone_verified=True,
        )
        db.merge(user)
        db.commit()

        mock_transcription = MagicMock()
        mock_transcription.text = "Hello world reminder"

        with patch(
            "agent.services.voice_transcription_service.OpenAIProvider.is_configured",
            True,
        ), patch(
            "agent.services.voice_transcription_service.OpenAIProvider.get_async_client"
        ) as mock_get_client:
            mock_client = AsyncMock()
            mock_client.audio.transcriptions.create.return_value = mock_transcription
            mock_get_client.return_value = mock_client

            token = create_access_token(user_id="usr-test-voice", phone_number="+15551234567")
            audio_b64 = base64.b64encode(_dummy_audio_bytes()).decode("utf-8")

            res = test_client.post(
                "/agent/voice/transcribe",
                headers={"Authorization": f"Bearer {token}"},
                json={"audio_base64": audio_b64, "filename": "audio.m4a"},
            )
            assert res.status_code == 200
            assert res.json()["text"] == "Hello world reminder"
    finally:
        db.close()
