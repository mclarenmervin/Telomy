"""A user's day starts where they live, not where the server runs.

The phone computes scores on local day boundaries. A server computing on UTC
boundaries would disagree for everyone outside UTC — 5.5 hours for IST — and
during the shadow comparison that looks exactly like a model bug while being
nothing of the kind.

The fix is a conversion layer, not a change to the scoring code: readings are
moved onto the user's local wall clock **before** any score sees them. The
ported algorithm stays byte-identical and provably so, and the timezone concern
lives in one testable place.

Output is deliberately naive. Once a reading is on the user's wall clock, its
offset has served its purpose, and carrying it further would reintroduce the
mixed-aware-and-naive comparisons `parse_ts` exists to prevent.
"""

from datetime import datetime, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.analytics.sleep import Reading
from app.common.logging_config import get_logger

logger = get_logger(__name__)

UTC = ZoneInfo("UTC")


def resolve_timezone(profile: dict | None) -> ZoneInfo:
    """The user's timezone, or UTC.

    A bad value falls back loudly: silently scoring someone against the wrong
    day is worse than a log line, and it is invisible from the outside.
    """
    name = ((profile or {}).get("timezone") or "").strip()
    if not name:
        return UTC
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        logger.error(f"unknown timezone {name!r}; scoring in UTC instead")
        return UTC


def to_wallclock(value: datetime, tz: ZoneInfo) -> datetime:
    """An instant as the user's clock showed it, naive.

    A naive input is assumed UTC — guessing the server's timezone would be the
    same bug this module exists to remove, in a different place.
    """
    aware = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    return aware.astimezone(tz).replace(tzinfo=None)


def localise(readings: list[Reading], tz: ZoneInfo) -> list[Reading]:
    """The same readings on the user's wall clock, everything else untouched."""
    return [
        Reading(
            measurement_type=r.measurement_type,
            value=r.value,
            recorded_at=to_wallclock(r.recorded_at, tz),
            ended_at=to_wallclock(r.ended_at, tz) if r.ended_at else None,
        )
        for r in readings
    ]
