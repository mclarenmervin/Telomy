import json
from datetime import datetime
from typing import Any


class JobQueue:
    """Thin wrapper over a Redis list. FIFO via LPUSH + BRPOP."""

    def __init__(self, redis_client: Any, queue_name: str):
        self._redis = redis_client
        self._queue_name = queue_name

    def enqueue(self, job: dict) -> None:
        self._redis.lpush(self._queue_name, json.dumps(job))

    def dequeue(self, timeout: int = 5) -> dict | None:
        result = self._redis.brpop(self._queue_name, timeout=timeout)
        if result is None:
            return None
        _, raw_job = result
        return json.loads(raw_job)
from datetime import datetime


class DelayedQueue:
    """A Redis sorted set used as a timer. Score is the due time, as a unix stamp.

    This is how an open event gets looked at again without any worker holding
    state or sleeping (P3): the due time lives in Redis, and whichever worker
    sweeps next promotes the job onto the normal work queue.
    """

    def __init__(self, redis_client: Any, key: str):
        self._redis = redis_client
        self._key = key

    def schedule(self, job: dict, due_at: datetime) -> None:
        # sort_keys makes the member deterministic, so rescheduling the same job
        # updates its due time rather than leaving a second copy behind.
        self._redis.zadd(self._key, {json.dumps(job, sort_keys=True): due_at.timestamp()})

    def promote_due(self, target: "JobQueue", now: datetime, limit: int = 100) -> int:
        due = self._redis.zrangebyscore(
            self._key, "-inf", now.timestamp(), start=0, num=limit
        )
        moved = 0
        for member in due:
            # Only the caller whose ZREM actually removed the member may enqueue
            # it; a concurrent sweeper gets 0 and skips. This is the whole
            # concurrency story for the timer.
            if self._redis.zrem(self._key, member):
                target.enqueue(json.loads(member))
                moved += 1
        return moved

    def pending(self) -> int:
        return int(self._redis.zcard(self._key))
