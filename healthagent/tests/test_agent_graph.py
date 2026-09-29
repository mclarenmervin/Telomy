from datetime import datetime, timedelta, timezone

from app.common.context_loader import ContextLoader
from app.agent.graph import build_agent
from app.agent.guardrails import SAFE_FALLBACK
from app.dev.synthetic import generate_readings
from tests.fakes import FakeSupabase

UTC = timezone.utc
NOW = datetime(2026, 9, 21, 12, 0, tzinfo=UTC)
START = NOW - timedelta(hours=3)
END = NOW - timedelta(hours=2)
ALICE = "00000000-0000-0000-0000-00000000000a"
BOB = "00000000-0000-0000-0000-00000000000b"
EVENT_ID = "22222222-2222-2222-2222-222222222222"


class FakeLLM:
    def __init__(self, reply="Your heart rate rose during the session."):
        self.reply, self.calls = reply, 0

    def complete(self, system, user):
        self.calls += 1
        return self.reply


def make_db(owner=ALICE, status="ended", with_readings=True):
    event = {
        "id": EVENT_ID, "user_id": owner, "event_type": "alcohol", "status": status,
        "started_at": START.isoformat(),
        "ended_at": END.isoformat() if status == "ended" else None,
    }
    readings = []
    if with_readings:
        readings = generate_readings(
            ALICE, NOW, days=14, seed=3, events=[("alcohol", START, END)]
        )
    return FakeSupabase({"events": [event], "health_measurements": readings})


def run(db, llm, user=ALICE, status="ended"):
    agent = build_agent(ContextLoader(db), llm, db)
    return agent.invoke({"user_id": user, "event_id": EVENT_ID, "status": status})


def test_started_event_saves_an_ack_without_calling_the_llm():
    db, llm = make_db(status="started"), FakeLLM()

    run(db, llm, status="started")

    rows = db.tables["predictions"]
    assert [r["kind"] for r in rows] == ["ack"]
    assert "alcohol" in rows[0]["summary"]
    assert llm.calls == 0


def test_ended_event_saves_an_analysis_from_the_llm():
    db, llm = make_db(), FakeLLM("Your heart rate rose during the session.")

    run(db, llm)

    row = db.tables["predictions"][0]
    assert row["kind"] == "analysis"
    assert row["user_id"] == ALICE
    assert row["data_quality"] == "full"
    assert row["summary"] == "Your heart rate rose during the session."
    assert row["analysis"]["metrics"]["heartRate"]["delta_during"] > 8
    assert row["guardrail_flags"] == []


def test_ended_event_with_no_readings_says_so_and_skips_the_llm():
    db, llm = make_db(with_readings=False), FakeLLM()

    run(db, llm)

    row = db.tables["predictions"][0]
    assert row["data_quality"] == "none"
    assert "don't have" in row["summary"].lower()
    assert llm.calls == 0


def test_unsafe_llm_output_is_replaced_and_flagged():
    db, llm = make_db(), FakeLLM("This is a clear diagnosis of a heart condition.")

    run(db, llm)

    row = db.tables["predictions"][0]
    assert row["summary"] == SAFE_FALLBACK
    assert row["guardrail_flags"] == ["diagnosis"]


def test_agent_works_without_an_llm():
    db = make_db()

    run(db, None)

    assert "heart rate" in db.tables["predictions"][0]["summary"]


def test_another_users_event_produces_nothing():
    db = make_db(owner=BOB)

    run(db, FakeLLM(), user=ALICE)

    assert db.tables.get("predictions", []) == []


def test_unhandled_status_produces_nothing():
    db = make_db(status="started")

    run(db, FakeLLM(), status="candidate")

    assert db.tables.get("predictions", []) == []


def test_user_id_is_never_changed_by_the_graph():
    db = make_db()

    result = run(db, FakeLLM())

    assert result["user_id"] == ALICE
