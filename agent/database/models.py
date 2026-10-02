import uuid
from datetime import datetime, timezone
from sqlalchemy import (
    Column,
    String,
    Text,
    Integer,
    Boolean,
    DateTime,
    Date,
    ForeignKey,
    Index,
)
from sqlalchemy.orm import relationship
from .connection import Base

def generate_uuid() -> str:
    return str(uuid.uuid4())

def get_utc_now():
    return datetime.now(timezone.utc)

class User(Base):
    __tablename__ = "users"

    id = Column(String(36), primary_key=True, default=generate_uuid)
    email = Column(String(255), unique=True, index=True, nullable=False)
    password_hash = Column(String(255), nullable=False)
    full_name = Column(String(255), nullable=True)
    phone_number = Column(String(32), nullable=True)
    phone_verified = Column(Boolean, default=False, nullable=False)
    created_at = Column(DateTime(timezone=True), default=get_utc_now, nullable=False)
    updated_at = Column(DateTime(timezone=True), default=get_utc_now, onupdate=get_utc_now, nullable=False)

    reminders = relationship("Reminder", back_populates="user", cascade="all, delete-orphan")
    verifications = relationship("PhoneVerification", back_populates="user", cascade="all, delete-orphan")
    action_logs = relationship("ActionHistory", back_populates="user")
    pending_confirmations = relationship("PendingWhatsAppConfirmation", back_populates="user", cascade="all, delete-orphan")

class Reminder(Base):
    __tablename__ = "reminders"

    id = Column(String(36), primary_key=True, default=generate_uuid)
    user_id = Column(String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    title = Column(String(255), nullable=False)
    description = Column(Text, nullable=True)
    due_date = Column(Date, nullable=True)
    due_hour = Column(Integer, nullable=True)
    due_minute = Column(Integer, nullable=True)
    priority = Column(String(16), default="medium", nullable=False)  # 'low', 'medium', 'high'
    recurrence = Column(String(32), default="none", nullable=False)   # 'none', 'daily', 'weekly', 'monthly'
    url = Column(String(1024), nullable=True)
    status = Column(String(32), default="PROPOSED", nullable=False)  # 'PROPOSED', 'CONFIRMED', 'CANCELLED', 'COMPLETED'
    completed_at = Column(DateTime(timezone=True), nullable=True)
    raw_prompt = Column(Text, nullable=True)
    created_at = Column(DateTime(timezone=True), default=get_utc_now, nullable=False)
    updated_at = Column(DateTime(timezone=True), default=get_utc_now, onupdate=get_utc_now, nullable=False)

    user = relationship("User", back_populates="reminders")
    channels = relationship("ReminderChannel", back_populates="reminder", cascade="all, delete-orphan")
    action_logs = relationship("ActionHistory", back_populates="reminder")

class ReminderChannel(Base):
    __tablename__ = "reminder_channels"

    id = Column(Integer, primary_key=True, autoincrement=True)
    reminder_id = Column(String(36), ForeignKey("reminders.id", ondelete="CASCADE"), nullable=False, index=True)
    channel = Column(String(32), nullable=False)  # 'local', 'whatsapp'
    status = Column(String(32), default="PENDING", nullable=False)  # 'PENDING', 'DISPATCHED', 'FAILED'
    dispatched_at = Column(DateTime(timezone=True), nullable=True)

    reminder = relationship("Reminder", back_populates="channels")

class PhoneVerification(Base):
    __tablename__ = "phone_verifications"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    phone_number = Column(String(32), nullable=False)
    verification_code = Column(String(16), nullable=False)
    expires_at = Column(DateTime(timezone=True), nullable=False)
    verified = Column(Boolean, default=False, nullable=False)
    created_at = Column(DateTime(timezone=True), default=get_utc_now, nullable=False)

    user = relationship("User", back_populates="verifications")

class ActionHistory(Base):
    __tablename__ = "action_history"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(String(36), ForeignKey("users.id", ondelete="SET NULL"), nullable=True, index=True)
    reminder_id = Column(String(36), ForeignKey("reminders.id", ondelete="SET NULL"), nullable=True, index=True)
    action_type = Column(String(64), nullable=False)  # 'PROPOSE_REMINDER', 'CONFIRM_REMINDER', 'DISPATCH_LOCAL', 'DISPATCH_WHATSAPP'
    details = Column(Text, nullable=True)
    success = Column(Boolean, default=True, nullable=False)
    created_at = Column(DateTime(timezone=True), default=get_utc_now, nullable=False)

    user = relationship("User", back_populates="action_logs")
    reminder = relationship("Reminder", back_populates="action_logs")

class PendingWhatsAppConfirmation(Base):
    __tablename__ = "pending_whatsapp_confirmations"

    id = Column(String(36), primary_key=True, default=generate_uuid)
    user_id = Column(String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    phone_number = Column(String(32), nullable=False, index=True)
    proposed_draft = Column(Text, nullable=False)
    status = Column(String(32), default="PENDING", nullable=False)  # 'PENDING', 'CONFIRMED', 'CANCELLED', 'EXPIRED'
    created_at = Column(DateTime(timezone=True), default=get_utc_now, nullable=False)
    expires_at = Column(DateTime(timezone=True), nullable=False)

    user = relationship("User", back_populates="pending_confirmations")
