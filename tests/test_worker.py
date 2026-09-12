from app.worker.handlers import process_event_job


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
