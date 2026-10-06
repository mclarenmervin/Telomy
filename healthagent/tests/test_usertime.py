"""A user's day starts where they live, not where the server runs.

The phone computes scores on local day boundaries; the server would compute
them on UTC boundaries. For IST that is a 5.5-hour difference in where a day
starts, which during a shadow comparison looks exactly like a model bug and is
not one.

Readings are converted to the user's local wall clock BEFORE any score sees
them, which leaves the ported algorithm untouched and provably identical.
"""

import logging
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from app.analytics.sleep import Reading
from app.common.usertime import localise, resolve_timezone, to_wallclock

UTC = timezone.utc


def test_a_profile_timezone_is_used():
    assert resolve_timezone({"timezone": "Asia/Kolkata"}) == ZoneInfo("Asia/Kolkata")


def test_a_missing_timezone_falls_back_to_utc():
    assert resolve_timezone({}) == ZoneInfo("UTC")
    assert resolve_timezone(None) == ZoneInfo("UTC")
    assert resolve_timezone({"timezone": ""}) == ZoneInfo("UTC")


def test_an_unknown_timezone_falls_back_loudly(caplog):
    """Silently scoring someone in the wrong day is worse than a log line."""
    with caplog.at_level(logging.ERROR):
        assert resolve_timezone({"timezone": "Mars/Olympus_Mons"}) == ZoneInfo("UTC")

    assert "Mars/Olympus_Mons" in caplog.text


def test_an_evening_utc_reading_is_the_next_day_in_india():
    """18:30 UTC is midnight in Kolkata — the exact case that would put a
    reading on the wrong day for every Indian user."""
    at = datetime(2026, 10, 1, 18, 30, tzinfo=UTC)

    local = to_wallclock(at, ZoneInfo("Asia/Kolkata"))

    assert local == datetime(2026, 10, 2, 0, 0)
    assert local.tzinfo is None


def test_wallclock_output_is_naive_so_the_ported_algorithm_is_unchanged():
    local = to_wallclock(datetime(2026, 10, 1, 12, tzinfo=UTC), ZoneInfo("Asia/Kolkata"))

    assert local.tzinfo is None


def test_a_naive_reading_is_assumed_to_be_utc():
    """Older rows may lack an offset; guessing the server's timezone would be
    the same bug in a different place."""
    naive = datetime(2026, 10, 1, 18, 30)

    assert to_wallclock(naive, ZoneInfo("Asia/Kolkata")) == datetime(2026, 10, 2, 0, 0)


def test_a_dst_transition_is_handled():
    """New York falls back on 2026-11-01. 05:30 UTC is 01:30 EDT; 06:30 UTC is
    01:30 EST — the same wall clock twice, which must not throw."""
    ny = ZoneInfo("America/New_York")

    assert to_wallclock(datetime(2026, 11, 1, 5, 30, tzinfo=UTC), ny).hour == 1
    assert to_wallclock(datetime(2026, 11, 1, 6, 30, tzinfo=UTC), ny).hour == 1


def test_localising_readings_preserves_everything_but_the_clock():
    kolkata = ZoneInfo("Asia/Kolkata")
    start = datetime(2026, 10, 1, 18, 30, tzinfo=UTC)
    readings = [Reading("sleep", 7.5, start, datetime(2026, 10, 2, 2, 0, tzinfo=UTC))]

    local = localise(readings, kolkata)

    assert local[0].measurement_type == "sleep"
    assert local[0].value == 7.5
    assert local[0].recorded_at == datetime(2026, 10, 2, 0, 0)
    assert local[0].ended_at == datetime(2026, 10, 2, 7, 30)


def test_localising_leaves_a_missing_end_missing():
    local = localise(
        [Reading("hrv", 55.0, datetime(2026, 10, 1, 12, tzinfo=UTC))],
        ZoneInfo("Asia/Kolkata"),
    )

    assert local[0].ended_at is None


def test_the_same_instant_lands_on_different_days_in_different_zones():
    """The property the whole module exists for."""
    at = datetime(2026, 10, 1, 20, 0, tzinfo=UTC)

    assert to_wallclock(at, ZoneInfo("UTC")).day == 1
    assert to_wallclock(at, ZoneInfo("Asia/Kolkata")).day == 2
