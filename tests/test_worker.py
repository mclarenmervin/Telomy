import os
from unittest.mock import patch

from app.worker.handlers import process_event_job
from app.worker.main import process_one

os.environ.setdefault("SUPABASE_URL", "https://x.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_KEY", "service-key")
os.environ.setdefault("WEBHOOK_SECRET", "shh")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379/0")
os.environ.setdefault("QUEUE_NAME", "events:realtime")

JOB = {"event_id": "e1", "user_id": "u1", "event_type": "alcohol", "status": "ended"}


class FakeAgent:
    def __init__(self, fail=False):
        self.fail, self.calls = fail, []

    def invoke(self, state):
        self.calls.append(state)
        if self.fail:
            raise RuntimeError("boom")
        return state


class StubQueue:
    def __init__(self, jobs):
        self._jobs = jobs

    def dequeue(self, timeout=5):
        return self._jobs.pop(0) if self._jobs else None


class RaisingQueue:
    """Simulates a transient Redis error (cold-start race, network blip)."""

    def dequeue(self, timeout=5):
        raise ConnectionError("connection refused")


def test_handler_runs_the_agent_with_identity_and_status():
    agent = FakeAgent()

    process_event_job(JOB, agent)

    assert agent.calls == [{"user_id": "u1", "event_id": "e1", "status": "ended"}]


def test_handler_does_not_raise_when_the_agent_fails():
    process_event_job(JOB, FakeAgent(fail=True))  # must not raise


def test_handler_does_not_raise_on_a_malformed_job():
    process_event_job({}, FakeAgent(fail=True))  # must not raise


def test_process_one_runs_a_job_when_present():
    agent = FakeAgent()

    handled = process_one(StubQueue([JOB]), agent, timeout=1)

    assert handled is True
    assert len(agent.calls) == 1


def test_process_one_returns_false_when_queue_empty():
    agent = FakeAgent()

    assert process_one(StubQueue([]), agent, timeout=1) is False
    assert agent.calls == []


def test_process_one_does_not_raise_when_dequeue_fails():
    agent = FakeAgent()

    assert process_one(RaisingQueue(), agent, timeout=1) is False
    assert agent.calls == []


def test_run_configures_socket_timeout_with_margin_over_dequeue_timeout():
    """
    Regression: BRPOP blocks server-side for its timeout then replies. If the
    client's socket_timeout has no margin over that, it gives up as the reply
    arrives and raises a spurious TimeoutError on nearly every empty poll.
    """
    from app.worker import main as worker_main

    with patch.object(worker_main.redis.Redis, "from_url") as mock_from_url, \
         patch.object(worker_main, "get_supabase_client"), \
         patch.object(worker_main, "build_llm", return_value=None), \
         patch.object(worker_main, "build_agent"), \
         patch.object(worker_main, "process_one", side_effect=KeyboardInterrupt):
        try:
            worker_main.run()
        except KeyboardInterrupt:
            pass

        _, kwargs = mock_from_url.call_args
        assert kwargs.get("socket_timeout", 0) >= 15
