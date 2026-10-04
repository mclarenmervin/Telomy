"""One timestamp parser, because mixing naive and aware datetimes raises at runtime.

Postgres hands back offsets, hand-written fixtures and older rows sometimes do
not, and `naive < aware` is a TypeError rather than a wrong answer — so it
surfaces as a crashed worker, not a bad number. Everything here comes out
aware and in UTC.
"""

from datetime import datetime, timezone


def parse_ts(value: str | datetime | None) -> datetime | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        parsed = value
    else:
        text = str(value).strip()
        if not text:
            return None
        try:
            parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
