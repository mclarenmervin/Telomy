from datetime import datetime, timedelta, timezone

import fakeredis

from app.common.queue import DelayedQueue, JobQueue

UTC = timezone.utc
NOW = datetime(2026, 10, 4, 20, 0, tzinfo=UTC)
JOB = {"event_id": "e1", "user_id": "u1", "status": "in_progress"}


def make_pair():
    redis_client = fakeredis.FakeStrictRedis()
    return (
        DelayedQueue(redis_client, "events:delayed"),
        JobQueue(redis_client, "events:realtime"),
    )


def test_a_job_scheduled_for_later_is_not_promoted_yet():
    delayed, queue = make_pair()
    delayed.schedule(JOB, NOW + timedelta(minutes=10))

    moved = delayed.promote_due(queue, NOW)

    assert moved == 0
    assert queue.dequeue(timeout=1) is None
    assert delayed.pending() == 1


def test_a_due_job_is_promoted_onto_the_work_queue_intact():
    delayed, queue = make_pair()
    delayed.schedule(JOB, NOW - timedelta(seconds=1))

    moved = delayed.promote_due(queue, NOW)

    assert moved == 1
    assert queue.dequeue(timeout=1) == JOB
    assert delayed.pending() == 0


def test_a_job_due_exactly_now_is_promoted():
    delayed, queue = make_pair()
    delayed.schedule(JOB, NOW)

    assert delayed.promote_due(queue, NOW) == 1


def test_promoting_twice_does_not_duplicate_the_job():
    """Two workers sweeping at once must not both enqueue the same check."""
    delayed, queue = make_pair()
    delayed.schedule(JOB, NOW - timedelta(seconds=1))

    first = delayed.promote_due(queue, NOW)
    second = delayed.promote_due(queue, NOW)

    assert (first, second) == (1, 0)
    assert queue.dequeue(timeout=1) == JOB
    assert queue.dequeue(timeout=1) is None


def test_only_due_jobs_are_promoted_when_several_are_waiting():
    delayed, queue = make_pair()
    delayed.schedule({"event_id": "due"}, NOW - timedelta(minutes=1))
    delayed.schedule({"event_id": "later"}, NOW + timedelta(minutes=30))

    moved = delayed.promote_due(queue, NOW)

    assert moved == 1
    assert queue.dequeue(timeout=1) == {"event_id": "due"}
    assert delayed.pending() == 1


def test_promotion_is_capped_by_the_limit():
    delayed, queue = make_pair()
    for index in range(5):
        delayed.schedule({"event_id": f"e{index}"}, NOW - timedelta(minutes=1))

    assert delayed.promote_due(queue, NOW, limit=2) == 2
    assert delayed.pending() == 3


def test_rescheduling_the_same_job_moves_its_due_time_instead_of_duplicating():
    delayed, queue = make_pair()
    delayed.schedule(JOB, NOW + timedelta(minutes=10))
    delayed.schedule(JOB, NOW - timedelta(seconds=1))

    assert delayed.pending() == 1
    assert delayed.promote_due(queue, NOW) == 1
