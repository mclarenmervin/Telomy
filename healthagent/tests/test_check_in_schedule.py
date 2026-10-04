from datetime import datetime, timedelta, timezone

from app.worker.check_in_schedule import next_check_in_due
from tests.fakes import make_settings

UTC = timezone.utc
NOW = datetime(2026, 10, 4, 21, 0, tzinfo=UTC)
SETTINGS = make_settings()


def event(status="started", started_at=NOW - timedelta(minutes=20)):
    return {"status": status, "started_at": started_at.isoformat()}


def test_a_started_event_schedules_the_first_check_one_interval_out():
    due = next_check_in_due(event(), "started", NOW, SETTINGS)

    assert due == NOW + timedelta(seconds=SETTINGS.check_in_interval_seconds)


def test_an_in_progress_check_schedules_the_next_one():
    due = next_check_in_due(event(), "in_progress", NOW, SETTINGS)

    assert due == NOW + timedelta(seconds=SETTINGS.check_in_interval_seconds)


def test_an_ended_event_stops_the_chain():
    assert next_check_in_due(event(status="ended"), "in_progress", NOW, SETTINGS) is None


def test_an_expired_event_stops_the_chain():
    assert next_check_in_due(event(status="expired"), "in_progress", NOW, SETTINGS) is None


def test_a_confirmed_event_keeps_checking():
    """Auto-detected events the user confirmed are open too (Phase 3)."""
    assert next_check_in_due(event(status="confirmed"), "in_progress", NOW, SETTINGS) is not None


def test_an_ended_job_does_not_schedule_anything():
    assert next_check_in_due(event(), "ended", NOW, SETTINGS) is None


def test_a_missing_event_schedules_nothing():
    assert next_check_in_due(None, "in_progress", NOW, SETTINGS) is None


def test_an_event_past_the_maximum_duration_stops_the_chain():
    """Regression: a user who forgot to tap stop must not be checked forever."""
    forgotten = event(started_at=NOW - timedelta(seconds=SETTINGS.check_in_max_seconds + 1))

    assert next_check_in_due(forgotten, "in_progress", NOW, SETTINGS) is None


def test_an_event_just_inside_the_maximum_duration_still_schedules():
    nearly = event(started_at=NOW - timedelta(seconds=SETTINGS.check_in_max_seconds - 60))

    assert next_check_in_due(nearly, "in_progress", NOW, SETTINGS) is not None


def test_a_naive_started_at_does_not_raise():
    """Regression: naive vs aware comparison is a TypeError, not a wrong number."""
    naive = {"status": "started", "started_at": "2026-10-04T20:40:00"}

    assert next_check_in_due(naive, "in_progress", NOW, SETTINGS) is not None


def test_an_unparseable_started_at_stops_the_chain():
    assert next_check_in_due(
        {"status": "started", "started_at": "nonsense"}, "in_progress", NOW, SETTINGS
    ) is None
