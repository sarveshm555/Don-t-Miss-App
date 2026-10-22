"""Voice audio transcription service for Don't Miss.

Uses the backend OpenAI Whisper model ('whisper-1') to transcribe spoken audio
into text. Validates file size, MIME types, and formats; prevents secret leaks
and avoids logging raw audio or sensitive data.
"""

import io
import logging
from typing import Optional, Set
from fastapi import HTTPException, status

from agent.providers.openai_provider import OpenAIProvider
from agent.models.reminder_schema import VoiceTranscribeResponse

logger = logging.getLogger(__name__)

ALLOWED_EXTENSIONS: Set[str] = {
    "m4a",
    "mp3",
    "webm",
    "wav",
    "ogg",
    "flac",
    "mp4",
    "mpeg",
    "mpga",
    "oga",
}

MIME_TYPE_MAP = {
    "m4a": "audio/m4a",
    "mp3": "audio/mpeg",
    "webm": "audio/webm",
    "wav": "audio/wav",
    "ogg": "audio/ogg",
    "flac": "audio/flac",
    "mp4": "audio/mp4",
    "mpeg": "audio/mpeg",
    "mpga": "audio/mpeg",
    "oga": "audio/ogg",
}

# 25 MB max limit as supported by OpenAI Whisper
MAX_FILE_SIZE_BYTES: int = 25 * 1024 * 1024


class VoiceTranscriptionService:
    """Service to safely process and transcribe user voice audio."""

    def __init__(self, openai_provider: Optional[OpenAIProvider] = None):
        self.openai_provider = openai_provider or OpenAIProvider()

    def validate_audio(self, audio_bytes: bytes, filename: str) -> str:
        """Validate audio file format, extension, and size.

        Returns normalized extension.
        """
        if not audio_bytes or len(audio_bytes) == 0:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Uploaded audio file is empty (0 bytes).",
            )

        if len(audio_bytes) > MAX_FILE_SIZE_BYTES:
            raise HTTPException(
                status_code=413,
                detail=f"Audio file exceeds maximum permitted size of 25 MB (got {len(audio_bytes)} bytes).",
            )

        # Extract and validate extension
        clean_name = filename.strip()
        if "." not in clean_name:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Audio file has no extension. Please provide an audio filename such as 'recording.m4a'.",
            )

        ext = clean_name.rsplit(".", 1)[-1].lower()
        if ext not in ALLOWED_EXTENSIONS:
            allowed_str = ", ".join(sorted(ALLOWED_EXTENSIONS))
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Unsupported audio format '{ext}'. Supported formats: {allowed_str}.",
            )

        return ext

    async def transcribe(
        self,
        audio_bytes: bytes,
        filename: Optional[str] = None,
        language: Optional[str] = None,
    ) -> VoiceTranscribeResponse:
        """Transcribe audio bytes using OpenAI Whisper."""
        fname = filename or "voice_recording.m4a"
        ext = self.validate_audio(audio_bytes, fname)
        mime_type = MIME_TYPE_MAP.get(ext, "application/octet-stream")

        if not self.openai_provider.is_configured:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="OpenAI API is not configured on the backend. Please check OPENAI_API_KEY.",
            )

        try:
            client = self.openai_provider.get_async_client()
            file_payload = (fname, audio_bytes, mime_type)

            kwargs = {
                "file": file_payload,
            }
            if language and language.strip():
                kwargs["language"] = language.strip()

            transcription = None
            # 1. Prefer gpt-4o-mini-transcribe, fallback to whisper-1 if unavailable
            try:
                transcription = await client.audio.transcriptions.create(
                    model="gpt-4o-mini-transcribe",
                    **kwargs,
                )
            except Exception as e:
                err_msg = str(e).lower()
                is_model_unsupported = (
                    "model" in err_msg
                    or "not_found" in err_msg
                    or "does not exist" in err_msg
                    or "not found" in err_msg
                    or "404" in err_msg
                    or "bad request" in err_msg
                    or "invalid" in err_msg
                )
                if is_model_unsupported:
                    logger.info("gpt-4o-mini-transcribe not available (%s); falling back to whisper-1", type(e).__name__)
                    transcription = await client.audio.transcriptions.create(
                        model="whisper-1",
                        **kwargs,
                    )
                else:
                    raise

            transcribed_text = (getattr(transcription, "text", "") or "").strip()

            if not transcribed_text:
                return VoiceTranscribeResponse(
                    success=True,
                    text="",
                    language=language,
                    filename=fname,
                    message="No speech detected in audio. Please speak clearly and try again.",
                )

            return VoiceTranscribeResponse(
                success=True,
                text=transcribed_text,
                language=language,
                filename=fname,
                message="Audio transcribed successfully.",
            )

        except HTTPException:
            raise
        except Exception as e:
            err_type = type(e).__name__
            err_msg = str(e).lower()
            logger.error(f"Voice transcription failed with error type: {err_type}")

            if "rate" in err_msg or "429" in err_msg:
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail="OpenAI transcription rate limit reached. Please try again shortly.",
                )
            if "timeout" in err_msg or "timed out" in err_msg:
                raise HTTPException(
                    status_code=status.HTTP_504_GATEWAY_TIMEOUT,
                    detail="OpenAI audio transcription request timed out. Please try again.",
                )
            if "auth" in err_msg or "api_key" in err_msg or "401" in err_msg:
                raise HTTPException(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    detail="OpenAI authentication failed on backend. Please check OPENAI_API_KEY.",
                )

            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail="Audio transcription failed via OpenAI. Please try again.",
            )
