from datetime import datetime, timedelta, timezone

from app.worker.check_in_schedule import (
    MAX_CONSECUTIVE_FAILURES,
    next_check_in_due,
    retry_check_in_due,
)
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


def promoted_job(status="in_progress", failures=0, started_at=NOW - timedelta(minutes=20)):
    """A job as the scheduler writes it: it carries started_at so the retry path
    can honour the duration cap without a database read."""
    job = {"event_id": "e1", "user_id": "u1", "status": status,
           "started_at": started_at.isoformat()}
    if failures:
        job["failures"] = failures
    return job


def test_a_failed_in_progress_job_is_retried_so_one_blip_does_not_end_the_chain():
    """Regression: a promoted job exists only because the previous run scheduled
    it, so no webhook retry covers it — a single transient read error would
    otherwise silence every remaining check-in for the event."""
    due = retry_check_in_due(promoted_job(), NOW, SETTINGS)

    assert due == NOW + timedelta(seconds=SETTINGS.check_in_interval_seconds)


def test_retries_stop_after_the_consecutive_failure_cap():
    assert retry_check_in_due(
        promoted_job(failures=MAX_CONSECUTIVE_FAILURES - 1), NOW, SETTINGS
    ) is not None
    assert retry_check_in_due(
        promoted_job(failures=MAX_CONSECUTIVE_FAILURES), NOW, SETTINGS
    ) is None


def test_a_failed_job_past_the_duration_cap_is_not_retried():
    forgotten = promoted_job(
        started_at=NOW - timedelta(seconds=SETTINGS.check_in_max_seconds + 1)
    )

    assert retry_check_in_due(forgotten, NOW, SETTINGS) is None


def test_a_job_without_started_at_is_not_retried():
    """A `started` job came from a webhook Supabase will retry, and carries no
    start time to bound the chain with, so the retry path leaves it alone."""
    assert retry_check_in_due(
        {"event_id": "e1", "user_id": "u1", "status": "started"}, NOW, SETTINGS
    ) is None


def test_an_ended_job_is_never_retried():
    assert retry_check_in_due(promoted_job(status="ended"), NOW, SETTINGS) is None
