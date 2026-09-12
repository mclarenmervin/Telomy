import json
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
