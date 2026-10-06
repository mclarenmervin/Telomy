"""The scheduler decides WHEN work happens; it never does the work.

Keeping it free of computation is what makes it stateless and restartable: due
times live in Redis, so a crashed scheduler loses nothing and a second replica
cannot double-enqueue.
"""

from datetime import date, datetime, timedelta, timezone

import fakeredis

from app.common.queue import DelayedQueue, JobQueue
from app.scheduler.plan import (
    SCORE_RECOMPUTE,
    active_user_ids,
    due_score_jobs,
    next_nightly_run,
)
from tests.fakes import FakeSupabase

UTC = timezone.utc
ALICE = "00000000-0000-0000-0000-00000000000a"
BOB = "00000000-0000-0000-0000-00000000000b"


def test_active_users_are_those_with_recent_measurements():
    """Scoring every account that ever existed is how a nightly sweep becomes
    the most expensive thing in the system."""
    now = datetime(2026, 10, 2, tzinfo=UTC)
    db = FakeSupabase({"health_measurements": [
        {"user_id": ALICE, "recorded_at": (now - timedelta(days=1)).isoformat()},
        {"user_id": BOB, "recorded_at": (now - timedelta(days=200)).isoformat()},
    ]})

    assert active_user_ids(db, now=now) == [ALICE]


def test_a_user_with_many_readings_is_listed_once():
    now = datetime(2026, 10, 2, tzinfo=UTC)
    db = FakeSupabase({"health_measurements": [
        {"user_id": ALICE, "recorded_at": (now - timedelta(hours=h)).isoformat()}
        for h in range(1, 20)
    ]})

    assert active_user_ids(db, now=now) == [ALICE]


def test_no_active_users_is_an_empty_sweep_not_an_error():
    assert active_user_ids(FakeSupabase({}), now=datetime(2026, 10, 2, tzinfo=UTC)) == []


def test_each_active_user_gets_one_recompute_job_for_yesterday():
    """Yesterday, not today: a day is only complete once it has ended."""
    now = datetime(2026, 10, 2, 3, 0, tzinfo=UTC)

    jobs = due_score_jobs([ALICE, BOB], now=now)

    assert [j["user_id"] for j in jobs] == [ALICE, BOB]
    assert {j["as_of"] for j in jobs} == {date(2026, 10, 1).isoformat()}
    assert {j["kind"] for j in jobs} == {SCORE_RECOMPUTE}


def test_the_nightly_run_is_scheduled_for_the_next_early_morning():
    assert next_nightly_run(datetime(2026, 10, 2, 3, 30, tzinfo=UTC)) == datetime(
        2026, 10, 3, 3, 0, tzinfo=UTC)


def test_a_run_before_the_hour_schedules_the_same_day():
    assert next_nightly_run(datetime(2026, 10, 2, 1, 0, tzinfo=UTC)) == datetime(
        2026, 10, 2, 3, 0, tzinfo=UTC)


def test_exactly_on_the_hour_schedules_the_next_day_not_a_tight_loop():
    assert next_nightly_run(datetime(2026, 10, 2, 3, 0, tzinfo=UTC)) == datetime(
        2026, 10, 3, 3, 0, tzinfo=UTC)


def test_scheduled_jobs_reach_the_work_queue_when_due():
    """End to end over the real DelayedQueue, which already has the ZREM-wins
    behaviour the timer relies on."""
    redis_client = fakeredis.FakeStrictRedis()
    delayed = DelayedQueue(redis_client, "scores:delayed")
    work = JobQueue(redis_client, "scores:batch")
    now = datetime(2026, 10, 2, 3, 0, tzinfo=UTC)

    for job in due_score_jobs([ALICE], now=now):
        delayed.schedule(job, now)

    assert delayed.promote_due(work, now) == 1
    assert work.dequeue(timeout=1)["user_id"] == ALICE


def test_the_same_job_scheduled_twice_is_promoted_once():
    """Two scheduler replicas must not double the nightly bill."""
    redis_client = fakeredis.FakeStrictRedis()
    delayed = DelayedQueue(redis_client, "scores:delayed")
    work = JobQueue(redis_client, "scores:batch")
    now = datetime(2026, 10, 2, 3, 0, tzinfo=UTC)
    job = due_score_jobs([ALICE], now=now)[0]

    delayed.schedule(job, now)
    delayed.schedule(job, now)

    assert delayed.promote_due(work, now) == 1


# ── The tick loop ────────────────────────────────────────────────────────────

class SpyDelayed:
    def __init__(self):
        self.scheduled = []
        self.promoted = 0

    def schedule(self, job, due_at):
        self.scheduled.append((job, due_at))

    def promote_due(self, target, now, limit=100):
        return self.promoted


def test_a_tick_promotes_due_work_and_schedules_the_next_sweep():
    from app.scheduler.main import tick

    delayed, db = SpyDelayed(), FakeSupabase({"health_measurements": [
        {"user_id": ALICE, "recorded_at": datetime(2026, 10, 1, tzinfo=UTC).isoformat()},
    ]})

    tick(db, delayed, work_queue=None, now=datetime(2026, 10, 2, 3, 0, tzinfo=UTC))

    kinds = [job["kind"] for job, _ in delayed.scheduled]
    assert SCORE_RECOMPUTE in kinds


def test_a_tick_outside_the_sweep_window_enqueues_no_recomputes():
    """The sweep runs once a night, not on every sixty-second tick."""
    from app.scheduler.main import tick

    delayed, db = SpyDelayed(), FakeSupabase({"health_measurements": [
        {"user_id": ALICE, "recorded_at": datetime(2026, 10, 1, tzinfo=UTC).isoformat()},
    ]})

    tick(db, delayed, work_queue=None, now=datetime(2026, 10, 2, 14, 0, tzinfo=UTC))

    assert [j for j, _ in delayed.scheduled if j["kind"] == SCORE_RECOMPUTE] == []


def test_a_failing_sweep_does_not_stop_the_tick_loop():
    from app.scheduler.main import tick

    class BoomDelayed(SpyDelayed):
        def schedule(self, job, due_at):
            raise ConnectionError("redis gone")

    # Must not raise.
    tick(FakeSupabase({}), BoomDelayed(), work_queue=None,
         now=datetime(2026, 10, 2, 3, 0, tzinfo=UTC))
