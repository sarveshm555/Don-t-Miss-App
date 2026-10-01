import os
import uuid
import logging
from datetime import datetime, timedelta, timezone
from fastapi import APIRouter, Depends, status
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session
from agent.database.connection import get_db_session
from agent.database.models import User, PhoneVerification
from agent.models.auth_schema import (
    UserSignUpRequest,
    UserSignInRequest,
    PhoneVerificationRequest,
    AuthResponse,
)
from agent.services.password_service import hash_password, verify_password
from agent.services.jwt_service import create_access_token, get_current_user_required

logger = logging.getLogger(__name__)

auth_router = APIRouter(prefix="/auth", tags=["Authentication"])

DEV_VERIFICATION_CODE = os.getenv("DEV_VERIFICATION_CODE", "123456")

def normalize_phone_number(phone: str) -> str:
    """Normalize phone number to international E.164-compatible format with leading +."""
    raw = phone.strip()
    digits_and_plus = "".join(c for c in raw if c.isdigit() or c == "+")
    if not digits_and_plus.startswith("+"):
        digits_and_plus = "+" + digits_and_plus
    return digits_and_plus

@auth_router.post("/signup", response_model=AuthResponse)
def sign_up(request: UserSignUpRequest, db: Session = Depends(get_db_session)):
    """Register a new user in PostgreSQL and create an initial verification record."""
    normalized_phone = normalize_phone_number(request.phone_number)

    # 1. Reject duplicate phone numbers
    existing_user = db.query(User).filter_by(phone_number=normalized_phone).first()
    if existing_user:
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=AuthResponse(
                success=False,
                message="Phone number is already registered.",
            ).model_dump(),
        )

    # 2. Generate unique email fallback for schema compatibility
    clean_digits = "".join(c for c in normalized_phone if c.isdigit())
    email = f"{clean_digits}@dontmiss.app"

    # 3. Hash password and persist user
    user = User(
        id=str(uuid.uuid4()),
        email=email,
        password_hash=hash_password(request.password),
        full_name=request.name.strip(),
        phone_number=normalized_phone,
        phone_verified=False,
    )
    db.add(user)

    # 4. Create phone verification record (15 minutes expiration)
    now = datetime.now(timezone.utc)
    verification = PhoneVerification(
        user_id=user.id,
        phone_number=normalized_phone,
        verification_code=DEV_VERIFICATION_CODE,
        expires_at=now + timedelta(minutes=15),
        verified=False,
    )
    db.add(verification)

    db.commit()
    db.refresh(user)

    # 5. Generate initial access token
    token = create_access_token(
        user_id=user.id,
        phone_number=user.phone_number,
        name=user.full_name,
    )

    return AuthResponse(
        success=True,
        user_id=user.id,
        name=user.full_name,
        phone_number=user.phone_number,
        is_verified=user.phone_verified,
        token=token,
        message="Account created successfully. Please verify your phone number.",
    )

@auth_router.post("/signin", response_model=AuthResponse)
def sign_in(request: UserSignInRequest, db: Session = Depends(get_db_session)):
    """Authenticate an existing user by phone number and password."""
    normalized_phone = normalize_phone_number(request.phone_number)

    user = db.query(User).filter_by(phone_number=normalized_phone).first()
    if not user:
        return JSONResponse(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=AuthResponse(
                success=False,
                message="Invalid phone number or password.",
            ).model_dump(),
        )

    if not verify_password(request.password, user.password_hash):
        return JSONResponse(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=AuthResponse(
                success=False,
                message="Invalid phone number or password.",
            ).model_dump(),
        )

    token = create_access_token(
        user_id=user.id,
        phone_number=user.phone_number,
        name=user.full_name,
    )

    return AuthResponse(
        success=True,
        user_id=user.id,
        name=user.full_name,
        phone_number=user.phone_number,
        is_verified=user.phone_verified,
        token=token,
        message="Signed in successfully.",
    )

@auth_router.post("/verify-phone", response_model=AuthResponse)
def verify_phone(request: PhoneVerificationRequest, db: Session = Depends(get_db_session)):
    """Verify phone number via verification code and transition user to verified."""
    normalized_phone = normalize_phone_number(request.phone_number)

    user = db.query(User).filter_by(phone_number=normalized_phone).first()
    if not user:
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=AuthResponse(
                success=False,
                message="User not found for this phone number.",
            ).model_dump(),
        )

    now = datetime.now(timezone.utc)
    # Query latest unverified verification entry that hasn't expired
    verification = (
        db.query(PhoneVerification)
        .filter(
            PhoneVerification.phone_number == normalized_phone,
            PhoneVerification.verified == False,
            PhoneVerification.expires_at > now,
        )
        .order_by(PhoneVerification.id.desc())
        .first()
    )

    if not verification or verification.verification_code != request.verification_code.strip():
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=AuthResponse(
                success=False,
                message="Invalid or expired verification code.",
            ).model_dump(),
        )

    # Transition verification and user state
    verification.verified = True
    user.phone_verified = True
    db.commit()
    db.refresh(user)

    token = create_access_token(
        user_id=user.id,
        phone_number=user.phone_number,
        name=user.full_name,
    )

    return AuthResponse(
        success=True,
        user_id=user.id,
        name=user.full_name,
        phone_number=user.phone_number,
        is_verified=True,
        token=token,
        message="Phone number verified successfully.",
    )

@auth_router.post("/signout")
def sign_out():
    """Client session termination acknowledgement."""
    return {"success": True, "message": "Signed out successfully."}

@auth_router.get("/me", response_model=AuthResponse)
def get_current_user_profile(user: User = Depends(get_current_user_required)):
    """Retrieve authenticated user profile for session validation."""
    return AuthResponse(
        success=True,
        user_id=user.id,
        name=user.full_name,
        phone_number=user.phone_number,
        is_verified=user.phone_verified,
        message="Authenticated session active.",
    )
