import fakeredis
from app.common.queue import JobQueue


def make_queue() -> JobQueue:
    redis_client = fakeredis.FakeStrictRedis()
    return JobQueue(redis_client, "events:realtime")


def test_enqueue_then_dequeue_returns_same_job():
    queue = make_queue()
    job = {"event_id": "e1", "user_id": "u1", "event_type": "alcohol"}

    queue.enqueue(job)
    result = queue.dequeue(timeout=1)

    assert result == job


def test_dequeue_empty_queue_returns_none():
    queue = make_queue()
    result = queue.dequeue(timeout=1)
    assert result is None


def test_enqueue_is_fifo():
    queue = make_queue()
    queue.enqueue({"event_id": "first"})
    queue.enqueue({"event_id": "second"})

    assert queue.dequeue(timeout=1) == {"event_id": "first"}
    assert queue.dequeue(timeout=1) == {"event_id": "second"}
