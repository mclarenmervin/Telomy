from datetime import datetime, timezone

from app.common.timeparse import parse_ts

UTC = timezone.utc


def test_offset_timestamp_is_parsed_as_aware():
    assert parse_ts("2026-10-04T12:00:00+00:00") == datetime(2026, 10, 4, 12, tzinfo=UTC)


def test_zulu_suffix_is_parsed():
    assert parse_ts("2026-10-04T12:00:00Z") == datetime(2026, 10, 4, 12, tzinfo=UTC)


def test_naive_timestamp_is_assumed_utc_and_stays_comparable():
    """Regression: a naive value compared against an aware now() raises TypeError."""
    parsed = parse_ts("2026-10-04T12:00:00")

    assert parsed == datetime(2026, 10, 4, 12, tzinfo=UTC)
    assert parsed < datetime.now(UTC)


def test_datetime_passes_through_as_aware():
    assert parse_ts(datetime(2026, 10, 4, 12)) == datetime(2026, 10, 4, 12, tzinfo=UTC)


def test_none_and_garbage_return_none():
    assert parse_ts(None) is None
    assert parse_ts("") is None
    assert parse_ts("not a timestamp") is None
