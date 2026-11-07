"""Timezone handling and UTC conversion utilities for Don't Miss.

Supports IANA timezone identifiers (e.g. 'Asia/Kolkata', 'America/New_York', 'UTC'),
abbreviations, and fixed numeric offsets with Daylight Saving Time support.
Converts local reminder dates/times to timezone-aware UTC timestamps for
accurate scheduling and comparison against UTC system clocks.
"""

import re
from datetime import datetime, date, timezone, timedelta, tzinfo
from typing import Optional, Any

DEFAULT_TIMEZONE = "Asia/Kolkata"

# Standard offset mapping for environments where system tzdata might be absent
TIMEZONE_ALIAS_MAP = {
    "asia/kolkata": timezone(timedelta(hours=5, minutes=30)),
    "ist": timezone(timedelta(hours=5, minutes=30)),
    "utc": timezone.utc,
    "gmt": timezone.utc,
    "z": timezone.utc,
    "america/new_york": timezone(timedelta(hours=-5)),
    "us/eastern": timezone(timedelta(hours=-5)),
    "est": timezone(timedelta(hours=-5)),
    "edt": timezone(timedelta(hours=-4)),
    "america/chicago": timezone(timedelta(hours=-6)),
    "us/central": timezone(timedelta(hours=-6)),
    "cst": timezone(timedelta(hours=-6)),
    "cdt": timezone(timedelta(hours=-5)),
    "america/denver": timezone(timedelta(hours=-7)),
    "us/mountain": timezone(timedelta(hours=-7)),
    "mst": timezone(timedelta(hours=-7)),
    "mdt": timezone(timedelta(hours=-6)),
    "america/los_angeles": timezone(timedelta(hours=-8)),
    "us/pacific": timezone(timedelta(hours=-8)),
    "pst": timezone(timedelta(hours=-8)),
    "pdt": timezone(timedelta(hours=-7)),
    "europe/london": timezone(timedelta(hours=0)),
    "bst": timezone(timedelta(hours=1)),
    "europe/paris": timezone(timedelta(hours=1)),
    "europe/berlin": timezone(timedelta(hours=1)),
    "cet": timezone(timedelta(hours=1)),
    "cest": timezone(timedelta(hours=2)),
    "asia/dubai": timezone(timedelta(hours=4)),
    "gst": timezone(timedelta(hours=4)),
    "asia/singapore": timezone(timedelta(hours=8)),
    "sgt": timezone(timedelta(hours=8)),
    "asia/tokyo": timezone(timedelta(hours=9)),
    "jst": timezone(timedelta(hours=9)),
    "australia/sydney": timezone(timedelta(hours=10)),
    "aest": timezone(timedelta(hours=10)),
    "aedt": timezone(timedelta(hours=11)),
}


def resolve_timezone(tz_name: Optional[str] = None) -> tzinfo:
    """Resolve a timezone identifier or alias to a tzinfo instance.

    Attempts standard library zoneinfo.ZoneInfo first (full IANA & DST support).
    Falls back gracefully to alias table or numeric offset parsing, with ultimate
    fallback to Asia/Kolkata (UTC+5:30).
    """
    name = (tz_name or "").strip()
    if not name or name.lower() in ("default", "none"):
        name = DEFAULT_TIMEZONE

    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo(name)
    except Exception:
        pass

    normalized = name.lower()
    if normalized in TIMEZONE_ALIAS_MAP:
        return TIMEZONE_ALIAS_MAP[normalized]

    iso_match = re.match(r"^([+-])(\d{1,2}):?(\d{2})?$", name)
    if iso_match:
        sign = -1 if iso_match.group(1) == "-" else 1
        hours = int(iso_match.group(2))
        minutes = int(iso_match.group(3) or 0)
        return timezone(timedelta(hours=sign * hours, minutes=sign * minutes))

    return timezone(timedelta(hours=5, minutes=30))


def reminder_due_to_utc(
    due_date: Any,
    due_hour: Optional[int],
    due_minute: Optional[int],
    tz_name: Optional[str] = DEFAULT_TIMEZONE,
) -> Optional[datetime]:
    """Convert local reminder due date and time into a timezone-aware UTC datetime.

    Accepts date, datetime, or ISO string (YYYY-MM-DD).
    Applies default hour 9 (09:00 AM) if due_hour is omitted but due_date is given.
    Returns None if due_date is None or cannot be parsed.
    """
    if not due_date:
        return None

    parsed_date: Optional[date] = None
    if isinstance(due_date, datetime):
        parsed_date = due_date.date()
    elif isinstance(due_date, date):
        parsed_date = due_date
    elif isinstance(due_date, str):
        clean_str = due_date.strip()
        if not clean_str:
            return None
        # Extract YYYY-MM-DD portion
        date_part = clean_str.split("T")[0].split(" ")[0]
        try:
            parsed_date = date.fromisoformat(date_part)
        except Exception:
            return None
    else:
        return None

    if not parsed_date:
        return None

    hour = due_hour if due_hour is not None else 9
    minute = due_minute if due_minute is not None else 0

    # Guard bounds
    hour = max(0, min(23, hour))
    minute = max(0, min(59, minute))

    tz = resolve_timezone(tz_name)
    local_dt = datetime(parsed_date.year, parsed_date.month, parsed_date.day, hour, minute)
    aware_dt = local_dt.replace(tzinfo=tz)
    return aware_dt.astimezone(timezone.utc)


def is_reminder_due_utc(
    due_utc: Optional[datetime],
    current_dt: Optional[datetime] = None,
) -> bool:
    """Determine if a timezone-aware UTC due timestamp has arrived or passed."""
    if due_utc is None:
        return False

    now_utc = current_dt or datetime.now(timezone.utc)
    if now_utc.tzinfo is None:
        now_utc = now_utc.replace(tzinfo=timezone.utc)
    if due_utc.tzinfo is None:
        due_utc = due_utc.replace(tzinfo=timezone.utc)

    return now_utc >= due_utc
