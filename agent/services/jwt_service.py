import os
from pathlib import Path
from datetime import datetime, timedelta, timezone
from typing import Optional
from dotenv import load_dotenv
import jwt
from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session
from agent.database.connection import get_db_session
from agent.database.models import User

# JWT Configuration
JWT_ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_DAYS = 7

bearer_scheme = HTTPBearer(auto_error=False)


def _load_env_file() -> None:
    """Load agent/.env or root .env if present without overriding existing runtime vars."""
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


def get_jwt_secret() -> str:
    """Retrieve the required JWT access secret from environment configuration.

    Fails with RuntimeError if JWT_ACCESS_SECRET is missing or blank.
    Never falls back to a hardcoded default in source code.
    """
    _load_env_file()
    secret = (os.getenv("JWT_ACCESS_SECRET") or "").strip()
    if not secret:
        raise RuntimeError(
            "JWT_ACCESS_SECRET is required but not configured in the environment. "
            "Please configure JWT_ACCESS_SECRET in your environment or .env file."
        )
    return secret


def create_access_token(
    user_id: str,
    phone_number: Optional[str] = None,
    name: Optional[str] = None,
    expires_delta: Optional[timedelta] = None,
) -> str:
    """Create a signed JWT access token containing the user ID and expiration."""
    secret = get_jwt_secret()
    now = datetime.now(timezone.utc)
    expire = now + (expires_delta or timedelta(days=ACCESS_TOKEN_EXPIRE_DAYS))
    payload = {
        "sub": user_id,
        "phone": phone_number,
        "name": name,
        "iat": int(now.timestamp()),
        "exp": int(expire.timestamp()),
    }
    return jwt.encode(payload, secret, algorithm=JWT_ALGORITHM)


def decode_access_token(token: str) -> dict:
    """Decode and validate a JWT access token.

    Raises jwt.ExpiredSignatureError or jwt.PyJWTError on invalid token.
    """
    secret = get_jwt_secret()
    return jwt.decode(token, secret, algorithms=[JWT_ALGORITHM])


def get_current_user_required(
    auth: Optional[HTTPAuthorizationCredentials] = Depends(bearer_scheme),
    db: Session = Depends(get_db_session),
) -> User:
    """Extract authenticated user or raise HTTP 401 if token is missing or invalid."""
    if not auth or not auth.credentials or not auth.credentials.strip():
        raise HTTPException(
            status_code=401,
            detail="Authentication token required.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    token = auth.credentials.strip()
    try:
        payload = decode_access_token(token)
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=401,
            detail="Token has expired.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    except (jwt.InvalidTokenError, jwt.PyJWTError):
        raise HTTPException(
            status_code=401,
            detail="Invalid authentication token.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    user_id = payload.get("sub")
    if not user_id:
        raise HTTPException(
            status_code=401,
            detail="Invalid token claims.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    user = db.query(User).filter_by(id=user_id).first()
    if not user:
        raise HTTPException(
            status_code=401,
            detail="User not found.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    return user


def get_current_user_optional(
    request: Request,
    auth: Optional[HTTPAuthorizationCredentials] = Depends(bearer_scheme),
    db: Session = Depends(get_db_session),
) -> Optional[User]:
    """Extract authenticated user if Bearer token is provided.

    If NO Authorization header is provided, returns None (anonymous/guest).
    If an Authorization header IS supplied but is invalid, expired, or malformed,
    raises HTTP 401 immediately instead of silently treating it as an anonymous/guest request.
    """
    auth_header = request.headers.get("authorization")
    if not auth_header or not auth_header.strip():
        return None
    if not auth or not auth.credentials or not auth.credentials.strip():
        raise HTTPException(
            status_code=401,
            detail="Invalid authentication token.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    return get_current_user_required(auth=auth, db=db)
