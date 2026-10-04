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
         patch.object(worker_main, "get_narration_model", return_value=None), \
         patch.object(worker_main, "build_agent"), \
         patch.object(worker_main, "process_one", side_effect=KeyboardInterrupt):
        try:
            worker_main.run()
        except KeyboardInterrupt:
            pass

        _, kwargs = mock_from_url.call_args
        assert kwargs.get("socket_timeout", 0) >= 15


from datetime import datetime, timedelta, timezone

from tests.fakes import make_settings

UTC = timezone.utc
SCHEDULE_NOW = datetime(2026, 10, 4, 21, 0, tzinfo=UTC)
OPEN_EVENT = {"status": "started", "started_at": (SCHEDULE_NOW - timedelta(minutes=5)).isoformat()}


class SpyDelayed:
    def __init__(self):
        self.scheduled = []

    def schedule(self, job, due_at):
        self.scheduled.append((job, due_at))


class EventAgent:
    """Returns the state a real graph run returns, including the loaded event."""

    def __init__(self, event):
        self._event = event
        self.calls = []

    def invoke(self, state):
        self.calls.append(state)
        return {**state, "event": self._event}


def test_a_started_job_schedules_the_first_check_in():
    delayed, agent = SpyDelayed(), EventAgent(OPEN_EVENT)
    settings = make_settings()

    process_event_job(
        {"event_id": "e1", "user_id": "u1", "status": "started"},
        agent, delayed=delayed, settings=settings, now=SCHEDULE_NOW,
    )

    assert len(delayed.scheduled) == 1
    job, due_at = delayed.scheduled[0]
    assert job == {"event_id": "e1", "user_id": "u1", "status": "in_progress"}
    assert due_at == SCHEDULE_NOW + timedelta(seconds=settings.check_in_interval_seconds)


def test_an_in_progress_job_reschedules_itself():
    delayed, agent = SpyDelayed(), EventAgent(OPEN_EVENT)

    process_event_job(
        {"event_id": "e1", "user_id": "u1", "status": "in_progress"},
        agent, delayed=delayed, settings=make_settings(), now=SCHEDULE_NOW,
    )

    assert [j["status"] for j, _ in delayed.scheduled] == ["in_progress"]


def test_an_ended_event_stops_rescheduling():
    delayed = SpyDelayed()
    agent = EventAgent({"status": "ended", "started_at": OPEN_EVENT["started_at"]})

    process_event_job(
        {"event_id": "e1", "user_id": "u1", "status": "in_progress"},
        agent, delayed=delayed, settings=make_settings(), now=SCHEDULE_NOW,
    )

    assert delayed.scheduled == []


def test_scheduling_is_skipped_entirely_when_no_delayed_queue_is_configured():
    agent = EventAgent(OPEN_EVENT)

    process_event_job({"event_id": "e1", "user_id": "u1", "status": "started"}, agent)

    assert len(agent.calls) == 1


def test_a_failing_agent_does_not_schedule_a_follow_up():
    delayed = SpyDelayed()

    process_event_job(
        {"event_id": "e1", "user_id": "u1", "status": "started"},
        FakeAgent(fail=True), delayed=delayed, settings=make_settings(), now=SCHEDULE_NOW,
    )

    assert delayed.scheduled == []


def test_a_failing_scheduler_does_not_break_the_job():
    class BoomDelayed:
        def schedule(self, job, due_at):
            raise ConnectionError("redis gone")

    process_event_job(  # must not raise
        {"event_id": "e1", "user_id": "u1", "status": "started"},
        EventAgent(OPEN_EVENT), delayed=BoomDelayed(),
        settings=make_settings(), now=SCHEDULE_NOW,
    )


class PromotingDelayed:
    def __init__(self, to_promote=0):
        self._to_promote = to_promote
        self.promotions = []
        self.scheduled = []

    def promote_due(self, target, now, limit=100):
        self.promotions.append(now)
        return self._to_promote

    def schedule(self, job, due_at):
        self.scheduled.append((job, due_at))


def test_process_one_sweeps_the_delayed_queue_before_reading_work():
    delayed, agent = PromotingDelayed(to_promote=1), FakeAgent()

    process_one(StubQueue([JOB]), agent, timeout=1, delayed=delayed,
                settings=make_settings())

    assert len(delayed.promotions) == 1
    assert len(agent.calls) == 1


def test_process_one_still_sweeps_when_there_is_no_work():
    delayed = PromotingDelayed()

    handled = process_one(StubQueue([]), FakeAgent(), timeout=1, delayed=delayed,
                          settings=make_settings())

    assert handled is False
    assert len(delayed.promotions) == 1


def test_a_failing_sweep_does_not_stop_the_worker_from_working():
    class BoomDelayed:
        def promote_due(self, target, now, limit=100):
            raise ConnectionError("redis gone")

        def schedule(self, job, due_at):
            pass

    agent = FakeAgent()

    handled = process_one(StubQueue([JOB]), agent, timeout=1, delayed=BoomDelayed(),
                          settings=make_settings())

    assert handled is True
    assert len(agent.calls) == 1


def test_run_builds_a_delayed_queue_from_the_configured_key():
    from app.worker import main as worker_main

    with patch.object(worker_main.redis.Redis, "from_url"), \
         patch.object(worker_main, "get_supabase_client"), \
         patch.object(worker_main, "get_narration_model", return_value=None), \
         patch.object(worker_main, "build_agent"), \
         patch.object(worker_main, "DelayedQueue") as mock_delayed, \
         patch.object(worker_main, "process_one", side_effect=KeyboardInterrupt):
        try:
            worker_main.run()
        except KeyboardInterrupt:
            pass

        args, _ = mock_delayed.call_args
        assert args[1] == "events:delayed"
