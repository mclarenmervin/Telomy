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
