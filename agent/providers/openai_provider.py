import os
import json
import logging
from pathlib import Path
from typing import Optional, Dict, Any
from dotenv import load_dotenv

logger = logging.getLogger(__name__)

def _load_env_file():
    """Load agent/.env or .env if present without overriding existing runtime vars."""
    candidates = [
        Path.cwd() / "agent" / ".env",
        Path.cwd() / ".env",
        Path(__file__).resolve().parent.parent / ".env",
        Path(__file__).resolve().parent.parent.parent / ".env",
    ]
    for candidate in candidates:
        if candidate.is_file():
            load_dotenv(candidate, override=False)
            break

_load_env_file()

class OpenAIProvider:
    """OpenAI API provider for Don't Miss AI Assistant.

    Provides structured reminder extraction using OpenAI's chat completions API
    with tool calling (function calling). Defaults to gpt-4o-mini.
    """

    def __init__(
        self,
        api_key: Optional[str] = None,
        model: Optional[str] = None,
    ):
        _load_env_file()
        self._api_key = api_key if api_key is not None else os.getenv("OPENAI_API_KEY")
        self._model = model or os.getenv("OPENAI_MODEL", "gpt-4o-mini")

    @property
    def api_key(self) -> Optional[str]:
        return self._api_key

    @property
    def model(self) -> str:
        return self._model

    @property
    def is_configured(self) -> bool:
        return bool(self._api_key and self._api_key.strip())

    def get_client(self):
        if not self.is_configured:
            raise RuntimeError(
                "OPENAI_API_KEY is not configured. "
                "Please configure OPENAI_API_KEY in your environment or Render environment variables."
            )
        from openai import OpenAI
        return OpenAI(api_key=self._api_key)

    def get_async_client(self):
        if not self.is_configured:
            raise RuntimeError(
                "OPENAI_API_KEY is not configured. "
                "Please configure OPENAI_API_KEY in your environment or Render environment variables."
            )
        from openai import AsyncOpenAI
        return AsyncOpenAI(api_key=self._api_key)

    def get_status_info(self) -> Dict[str, Any]:
        return {
            "ai_provider": "openai",
            "model": self.model,
            "configured": self.is_configured,
        }
