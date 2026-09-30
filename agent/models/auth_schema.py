"""Authentication schemas for Don't Miss.

Prepares data structures for future user signup, signin, and mobile/WhatsApp verification.
"""

from typing import Optional
from pydantic import BaseModel, Field

class UserSignUpRequest(BaseModel):
    name: str = Field(..., min_length=1, description="User's full name")
    phone_number: str = Field(..., description="Mobile / WhatsApp number with country code")
    password: str = Field(..., min_length=6, description="User password")

class UserSignInRequest(BaseModel):
    phone_number: str = Field(..., description="Mobile / WhatsApp number with country code")
    password: str = Field(..., description="User password")

class PhoneVerificationRequest(BaseModel):
    phone_number: str = Field(..., description="Mobile / WhatsApp number")
    verification_code: str = Field(..., min_length=4, max_length=6, description="Verification code")

class AuthResponse(BaseModel):
    success: bool
    user_id: Optional[str] = None
    name: Optional[str] = None
    phone_number: Optional[str] = None
    is_verified: bool = False
    token: Optional[str] = None
    message: str
