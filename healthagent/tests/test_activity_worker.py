from app.activity_worker.handlers import process_activity_job
from app.activity_worker.main import process_one


class SpyAgent:
    def __init__(self, boom=False):
        self.calls, self.boom = [], boom

    def invoke(self, payload, **kwargs):
        self.calls.append((payload, kwargs))
        if self.boom:
            raise RuntimeError("model exploded")
        return {}


class OneJobQueue:
    def __init__(self, job):
        self.job = job

    def dequeue(self, timeout=5):
        job, self.job = self.job, None
        return job


class BrokenQueue:
    def dequeue(self, timeout=5):
        raise ConnectionError("redis gone")


def test_job_becomes_context_and_thread_id():
    agent = SpyAgent()
    process_activity_job({"user_id": "u1", "session_id": "s1"}, agent, 60)
    _, kwargs = agent.calls[0]
    assert kwargs["context"] == {"user_id": "u1", "session_id": "s1"}
    assert kwargs["config"]["configurable"]["thread_id"] == "s1"


def test_a_failing_agent_does_not_kill_the_worker():
    process_activity_job({"user_id": "u1", "session_id": "s1"}, SpyAgent(boom=True), 60)


def test_a_malformed_job_is_skipped():
    agent = SpyAgent()
    process_activity_job({"user_id": "u1"}, agent, 60)
    assert agent.calls == []


def test_process_one_reports_whether_it_did_work():
    agent = SpyAgent()
    queue = OneJobQueue({"user_id": "u1", "session_id": "s1"})
    assert process_one(queue, agent, timeout=0, wall_clock_seconds=60) is True
    assert process_one(queue, agent, timeout=0, wall_clock_seconds=60) is False


def test_a_broken_queue_does_not_kill_the_worker():
    assert process_one(BrokenQueue(), SpyAgent(), timeout=0, wall_clock_seconds=60) is False


# --- review fix pass ---------------------------------------------------------


class SlowAgent:
    def __init__(self, seconds):
        self.seconds = seconds
        self.started = False

    def invoke(self, payload, **kwargs):
        import time

        self.started = True
        time.sleep(self.seconds)
        return {}


class RecordingQueue:
    def __init__(self):
        self.enqueued = []

    def enqueue(self, job):
        self.enqueued.append(job)


def test_a_hung_job_releases_the_worker_at_the_deadline():
    """Finding 8: wall_clock_seconds was accepted and never used."""
    import time

    agent = SlowAgent(seconds=5)
    started = time.monotonic()
    process_activity_job({"user_id": "u1", "session_id": "s1"}, agent, wall_clock_seconds=1)
    elapsed = time.monotonic() - started
    assert agent.started is True
    assert elapsed < 3, f"worker blocked for {elapsed:.1f}s despite a 1s deadline"


def test_a_transient_failure_is_requeued_for_one_retry():
    """Finding 9: a Supabase blip lost the report silently, with no retry."""
    queue = RecordingQueue()
    process_activity_job(
        {"user_id": "u1", "session_id": "s1"}, SpyAgent(boom=True), 60, queue=queue
    )
    assert queue.enqueued == [{"user_id": "u1", "session_id": "s1", "attempt": 2}]


def test_retries_are_bounded():
    queue = RecordingQueue()
    process_activity_job(
        {"user_id": "u1", "session_id": "s1", "attempt": 2}, SpyAgent(boom=True), 60, queue=queue
    )
    assert queue.enqueued == []  # give up rather than loop forever
