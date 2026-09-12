import os
from unittest.mock import patch
from app.worker.handlers import process_event_job

os.environ.setdefault("SUPABASE_URL", "https://x.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_KEY", "service-key")
os.environ.setdefault("WEBHOOK_SECRET", "shh")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379/0")
os.environ.setdefault("QUEUE_NAME", "events:realtime")


class FakeTable:
    def __init__(self, store: list):
        self._store = store
        self._pending_row = None

    def insert(self, row: dict):
        self._pending_row = row
        return self

    def execute(self):
        self._store.append(self._pending_row)


class FakeSupabase:
    def __init__(self):
        self.rows: list = []

    def table(self, name: str):
        assert name == "debug_log"
        return FakeTable(self.rows)


class FailingSupabase:
    def table(self, name: str):
        raise RuntimeError("connection refused")


def test_process_event_job_writes_debug_row():
    supabase = FakeSupabase()
    job = {"event_id": "e1", "user_id": "u1", "event_type": "alcohol"}

    process_event_job(job, supabase)

    assert supabase.rows == [
        {
            "event_id": "e1",
            "user_id": "u1",
            "event_type": "alcohol",
            "note": "worker received this event",
        }
    ]


def test_process_event_job_does_not_raise_on_supabase_failure():
    supabase = FailingSupabase()
    job = {"event_id": "e1", "user_id": "u1", "event_type": "alcohol"}

    process_event_job(job, supabase)  # must not raise


from app.worker.main import process_one


class StubQueue:
    def __init__(self, jobs: list):
        self._jobs = jobs

    def dequeue(self, timeout: int = 5):
        if not self._jobs:
            return None
        return self._jobs.pop(0)


def test_process_one_returns_true_and_processes_job_when_present():
    supabase = FakeSupabase()
    queue = StubQueue([{"event_id": "e1", "user_id": "u1", "event_type": "alcohol"}])

    handled = process_one(queue, supabase, timeout=1)

    assert handled is True
    assert supabase.rows[0]["event_id"] == "e1"


def test_process_one_returns_false_when_queue_empty():
    supabase = FakeSupabase()
    queue = StubQueue([])

    handled = process_one(queue, supabase, timeout=1)

    assert handled is False
    assert supabase.rows == []


class RaisingQueue:
    """Simulates a transient Redis error (e.g. cold-start race, network blip)."""

    def dequeue(self, timeout: int = 5):
        raise ConnectionError("connection refused")


def test_process_one_does_not_raise_when_dequeue_fails():
    supabase = FakeSupabase()
    queue = RaisingQueue()

    handled = process_one(queue, supabase, timeout=1)  # must not raise

    assert handled is False
    assert supabase.rows == []


def test_run_configures_socket_timeout_with_margin_over_dequeue_timeout():
    """
    Regression test: BRPOP blocks server-side for up to its `timeout` argument,
    then replies. If the client's own socket_timeout is equal to (or less
    than) that, the client can give up right as the reply arrives, raising a
    spurious redis.exceptions.TimeoutError on nearly every empty poll. The
    client's socket_timeout must have real margin over the BRPOP timeout used
    in process_one/dequeue (5s default).
    """
    from app.worker import main as worker_main

    with patch.object(worker_main.redis.Redis, "from_url") as mock_from_url, \
         patch.object(worker_main, "get_supabase_client"), \
         patch.object(worker_main, "process_one", side_effect=KeyboardInterrupt):
        try:
            worker_main.run()
        except KeyboardInterrupt:
            pass

        _, kwargs = mock_from_url.call_args
        assert kwargs.get("socket_timeout", 0) >= 15  # comfortable margin over the 5s BRPOP timeout
