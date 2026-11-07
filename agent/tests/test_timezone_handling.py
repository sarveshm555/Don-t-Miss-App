"""Comprehensive test suite for timezone-aware reminder scheduling and conversion.

Tests:
1. Timezone resolution across IANA, aliases, and numeric offsets.
2. Conversion of local dates/hours/minutes to UTC across IST, UTC, US, Europe, and Asia.
3. Date boundary rollovers across midnight in both directions.
4. Default hour/minute handling (omitted hours defaulting to 9:00 AM).
5. Due timestamp comparison and non-blocking evaluation.
6. Backward compatibility for legacy reminders without due_timestamp_utc.
7. Scheduler idempotency and duplicate notification prevention.
"""

import pytest
import datetime
from unittest.mock import MagicMock
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from agent.database.models import Base, User, Reminder, ReminderChannel, ActionHistory, generate_uuid
from agent.services.timezone_service import (
    resolve_timezone,
    reminder_due_to_utc,
    is_reminder_due_utc,
)
from agent.services.reminder_scheduler import ReminderScheduler
from agent.services.batch_reminder_service import is_reminder_due_now


class TestTimezoneResolution:
    def test_default_is_asia_kolkata(self):
        tz = resolve_timezone(None)
        assert tz is not None
        # Asia/Kolkata is UTC+5:30
        now = datetime.datetime.now(tz)
        offset = now.utcoffset()
        assert offset == datetime.timedelta(hours=5, minutes=30)

    def test_resolve_standard_aliases(self):
        for name in ["Asia/Kolkata", "ist", "IST"]:
            tz = resolve_timezone(name)
            now = datetime.datetime.now(tz)
            assert now.utcoffset() == datetime.timedelta(hours=5, minutes=30)

        for name in ["utc", "UTC", "gmt", "GMT"]:
            tz = resolve_timezone(name)
            now = datetime.datetime.now(tz)
            assert now.utcoffset() == datetime.timedelta(0)

    def test_resolve_numeric_offsets(self):
        tz = resolve_timezone("+05:30")
        now = datetime.datetime.now(tz)
        assert now.utcoffset() == datetime.timedelta(hours=5, minutes=30)

        tz_minus = resolve_timezone("-04:00")
        now_minus = datetime.datetime.now(tz_minus)
        assert now_minus.utcoffset() == datetime.timedelta(hours=-4)

    def test_resolve_unknown_falls_back_to_kolkata(self):
        tz = resolve_timezone("Unknown/Place_XYZ")
        now = datetime.datetime.now(tz)
        assert now.utcoffset() == datetime.timedelta(hours=5, minutes=30)


class TestReminderDueToUtc:
    def test_ist_morning_conversion(self):
        # 9:00 AM IST on Nov 10, 2026 -> 03:30 AM UTC on Nov 10, 2026
        due_utc = reminder_due_to_utc("2026-11-10", 9, 0, "Asia/Kolkata")
        assert due_utc is not None
        assert due_utc.tzinfo == datetime.timezone.utc
        assert due_utc.year == 2026
        assert due_utc.month == 11
        assert due_utc.day == 10
        assert due_utc.hour == 3
        assert due_utc.minute == 30

    def test_utc_conversion(self):
        # 9:00 AM UTC on Nov 10, 2026 -> 09:00 AM UTC on Nov 10, 2026
        due_utc = reminder_due_to_utc("2026-11-10", 9, 0, "UTC")
        assert due_utc is not None
        assert due_utc.hour == 9
        assert due_utc.minute == 0
        assert due_utc.day == 10

    def test_pst_date_boundary_rollover_forward(self):
        # 11:30 PM PST (-8) on Nov 10, 2026 -> 07:30 AM UTC on Nov 11, 2026
        due_utc = reminder_due_to_utc("2026-11-10", 23, 30, "America/Los_Angeles")
        assert due_utc is not None
        assert due_utc.day == 11
        assert due_utc.hour == 7
        assert due_utc.minute == 30

    def test_sydney_date_boundary_rollover_backward(self):
        # 1:00 AM in Sydney (+10 in AEST / standard fallback) on Nov 10, 2026 -> 15:00 UTC on Nov 9, 2026
        due_utc = reminder_due_to_utc("2026-11-10", 1, 0, "Australia/Sydney")
        assert due_utc is not None
        assert due_utc.day == 9
        # 1:00 AM minus 10 hours = 15:00 UTC previous day (or 14:00 if AEDT +11)
        assert due_utc.hour in (14, 15)
        assert due_utc.minute == 0

    def test_omitted_hour_defaults_to_nine_am(self):
        # Missing hour defaults to 9:00 AM local
        due_utc = reminder_due_to_utc("2026-11-10", None, None, "Asia/Kolkata")
        assert due_utc is not None
        assert due_utc.hour == 3
        assert due_utc.minute == 30

    def test_missing_or_invalid_date_returns_none(self):
        assert reminder_due_to_utc(None, 9, 0) is None
        assert reminder_due_to_utc("not-a-date", 9, 0) is None


class TestIsReminderDueUtc:
    def test_past_due(self):
        due = datetime.datetime(2026, 11, 10, 10, 0, tzinfo=datetime.timezone.utc)
        current = datetime.datetime(2026, 11, 10, 10, 5, tzinfo=datetime.timezone.utc)
        assert is_reminder_due_utc(due, current) is True

    def test_not_yet_due(self):
        due = datetime.datetime(2026, 11, 10, 10, 0, tzinfo=datetime.timezone.utc)
        current = datetime.datetime(2026, 11, 10, 9, 55, tzinfo=datetime.timezone.utc)
        assert is_reminder_due_utc(due, current) is False

    def test_exact_time_due(self):
        due = datetime.datetime(2026, 11, 10, 10, 0, tzinfo=datetime.timezone.utc)
        current = datetime.datetime(2026, 11, 10, 10, 0, tzinfo=datetime.timezone.utc)
        assert is_reminder_due_utc(due, current) is True


class TestSchedulerAndTimezoneIntegration:
    @pytest.fixture
    def test_db(self):
        engine = create_engine("sqlite:///:memory:")
        Base.metadata.create_all(engine)
        Session = sessionmaker(bind=engine)
        session = Session()
        yield session
        session.close()

    def test_scheduler_evaluates_due_timestamp_utc_correctly(self):
        scheduler = ReminderScheduler()
        # Due at 03:30 UTC (which is 9:00 AM IST)
        due_utc = datetime.datetime(2026, 11, 10, 3, 30, tzinfo=datetime.timezone.utc)
        reminder = Reminder(
            id="rem-test-1",
            title="Meeting with client",
            due_date=datetime.date(2026, 11, 10),
            due_hour=9,
            due_minute=0,
            timezone="Asia/Kolkata",
            due_timestamp_utc=due_utc,
        )

        # At 03:00 UTC (8:30 AM IST) -> NOT due
        current_early = datetime.datetime(2026, 11, 10, 3, 0, tzinfo=datetime.timezone.utc)
        assert scheduler.is_reminder_due(reminder, current_early) is False

        # At 03:30 UTC (9:00 AM IST) -> DUE!
        current_exact = datetime.datetime(2026, 11, 10, 3, 30, tzinfo=datetime.timezone.utc)
        assert scheduler.is_reminder_due(reminder, current_exact) is True

        # At 04:00 UTC (9:30 AM IST) -> DUE!
        current_late = datetime.datetime(2026, 11, 10, 4, 0, tzinfo=datetime.timezone.utc)
        assert scheduler.is_reminder_due(reminder, current_late) is True

    def test_scheduler_legacy_fallback_when_due_timestamp_is_none(self):
        scheduler = ReminderScheduler()
        # Older legacy row without due_timestamp_utc
        reminder = Reminder(
            id="rem-test-legacy",
            title="Legacy tax payment",
            due_date=datetime.date(2026, 11, 10),
            due_hour=9,
            due_minute=0,
            timezone="Asia/Kolkata",
            due_timestamp_utc=None,
        )

        # At 03:00 UTC (8:30 AM IST) -> NOT due
        current_early = datetime.datetime(2026, 11, 10, 3, 0, tzinfo=datetime.timezone.utc)
        assert scheduler.is_reminder_due(reminder, current_early) is False

        # At 03:35 UTC (9:05 AM IST) -> DUE via on-the-fly conversion!
        current_due = datetime.datetime(2026, 11, 10, 3, 35, tzinfo=datetime.timezone.utc)
        assert scheduler.is_reminder_due(reminder, current_due) is True

    def test_batch_service_is_reminder_due_now(self):
        due_utc = datetime.datetime(2026, 11, 10, 3, 30, tzinfo=datetime.timezone.utc)
        rem = Reminder(
            id="rem-batch-1",
            title="Batch task",
            due_date=datetime.date(2026, 11, 10),
            due_hour=9,
            due_minute=0,
            timezone="Asia/Kolkata",
            due_timestamp_utc=due_utc,
        )

        before = datetime.datetime(2026, 11, 10, 3, 15, tzinfo=datetime.timezone.utc)
        after = datetime.datetime(2026, 11, 10, 3, 45, tzinfo=datetime.timezone.utc)
        assert is_reminder_due_now(rem, before) is False
        assert is_reminder_due_now(rem, after) is True

    def test_duplicate_notification_prevention(self, test_db):
        # Create user, reminder, and pending channel
        user = User(
            id="usr-dup-test",
            email="dup@test.com",
            password_hash="hashed_pw_test",
            phone_number="+919876543210",
            phone_verified=True,
            timezone="Asia/Kolkata",
        )
        test_db.add(user)

        due_utc = datetime.datetime(2026, 11, 10, 3, 30, tzinfo=datetime.timezone.utc)
        reminder = Reminder(
            id="rem-dup-test",
            user_id=user.id,
            title="Exclusive dispatch",
            due_date=datetime.date(2026, 11, 10),
            due_hour=9,
            due_minute=0,
            timezone="Asia/Kolkata",
            due_timestamp_utc=due_utc,
            status="CONFIRMED",
        )
        test_db.add(reminder)

        channel = ReminderChannel(
            reminder_id=reminder.id,
            channel="whatsapp",
            status="PENDING",
        )
        test_db.add(channel)
        test_db.commit()

        # Mock TwilioWhatsAppService
        mock_wa = MagicMock()
        mock_wa.send_reminder_sync.return_value = {"success": True, "message_sid": "SM123"}
        scheduler = ReminderScheduler(whatsapp_service=mock_wa)

        # Trigger run 1 at due time
        now_utc = datetime.datetime(2026, 11, 10, 3, 35, tzinfo=datetime.timezone.utc)
        res1 = scheduler.process_due_reminders(test_db, current_dt=now_utc)
        assert len(res1) == 1
        assert res1[0]["status"] == "DISPATCHED"
        assert res1[0]["success"] is True
        assert mock_wa.send_reminder_sync.call_count == 1

        # Channel status must now be DISPATCHED in db
        test_db.refresh(channel)
        assert channel.status == "DISPATCHED"

        # Trigger run 2 immediately after -> Must NOT send again (0 dispatches)
        res2 = scheduler.process_due_reminders(test_db, current_dt=now_utc)
        assert len(res2) == 0
        assert mock_wa.send_reminder_sync.call_count == 1  # Still 1, no duplicate!
