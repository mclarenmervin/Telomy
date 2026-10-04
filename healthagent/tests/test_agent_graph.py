from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

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
    """Stands in for a LangChain chat model: invoke(messages) -> object with .content."""

    def __init__(self, reply="Your heart rate rose during the session."):
        self.reply, self.calls = reply, 0

    def invoke(self, messages):
        self.calls += 1
        return SimpleNamespace(content=self.reply)


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


from app.analytics.check_in import PRIORITY, REASON_HR

IN_PROGRESS_NOW = START + timedelta(minutes=45)


def make_open_db(owner=ALICE, status="started", event_type="alcohol", with_readings=True):
    """An event that is still open, with readings up to IN_PROGRESS_NOW."""
    event = {
        "id": EVENT_ID, "user_id": owner, "event_type": event_type, "status": status,
        "started_at": START.isoformat(), "ended_at": None,
    }
    readings = []
    if with_readings:
        readings = generate_readings(
            ALICE, IN_PROGRESS_NOW, days=14, seed=3,
            events=[(event_type, START, IN_PROGRESS_NOW)],
        )
    return FakeSupabase({"events": [event], "health_measurements": readings})


def run_in_progress(db, llm, user=ALICE, now=IN_PROGRESS_NOW):
    agent = build_agent(ContextLoader(db), llm, db)
    return agent.invoke({
        "user_id": user, "event_id": EVENT_ID,
        "status": "in_progress", "now": now.isoformat(),
    })


def test_in_progress_check_writes_a_check_in_when_a_rule_fires():
    db, llm = make_open_db(event_type="sauna"), FakeLLM("Your heart rate is climbing.")

    run_in_progress(db, llm)

    rows = db.tables["predictions"]
    assert len(rows) == 1
    assert rows[0]["kind"] == f"check_in:{REASON_HR}"
    assert rows[0]["user_id"] == ALICE
    assert rows[0]["summary"] == "Your heart rate is climbing."


def test_a_quiet_in_progress_check_writes_nothing_and_skips_the_llm():
    db, llm = make_open_db(event_type="eating"), FakeLLM()

    run_in_progress(db, llm)

    assert db.tables.get("predictions", []) == []
    assert llm.calls == 0


def test_an_in_progress_check_with_no_readings_stays_silent():
    db, llm = make_open_db(with_readings=False), FakeLLM()

    run_in_progress(db, llm)

    assert db.tables.get("predictions", []) == []
    assert llm.calls == 0


def test_a_reason_already_delivered_is_never_sent_twice():
    """Regression: the same reason buzzing every ten minutes is how users switch
    notifications off. A *different* reason may still fire (design §3.3)."""
    db, llm = make_open_db(event_type="sauna"), FakeLLM()
    db.tables["predictions"] = [
        {"user_id": ALICE, "event_id": EVENT_ID, "kind": f"check_in:{REASON_HR}",
         "summary": "already said"},
    ]

    run_in_progress(db, llm)

    # The already-delivered row must be untouched: if the rule re-fired on the
    # same reason, the upsert on (event_id, kind) would overwrite this summary
    # with a fresh narration and the user would be buzzed about it twice.
    hr_rows = [r for r in db.tables["predictions"] if r["kind"] == f"check_in:{REASON_HR}"]
    assert len(hr_rows) == 1
    assert hr_rows[0]["summary"] == "already said"


def test_every_reason_already_delivered_means_silence_and_no_llm_call():
    db, llm = make_open_db(event_type="sauna"), FakeLLM()
    db.tables["predictions"] = [
        {"user_id": ALICE, "event_id": EVENT_ID, "kind": f"check_in:{reason}",
         "summary": "already said"}
        for reason in PRIORITY
    ]

    run_in_progress(db, llm)

    assert len(db.tables["predictions"]) == len(PRIORITY)
    assert llm.calls == 0


def test_an_event_that_ended_before_the_check_ran_produces_nothing():
    """Regression: the timer fires after the user tapped stop."""
    db, llm = make_open_db(event_type="sauna", status="ended"), FakeLLM()

    run_in_progress(db, llm)

    assert db.tables.get("predictions", []) == []
    assert llm.calls == 0


def test_an_in_progress_check_on_another_users_event_produces_nothing():
    db, llm = make_open_db(owner=BOB, event_type="sauna"), FakeLLM()

    run_in_progress(db, llm, user=ALICE)

    assert db.tables.get("predictions", []) == []
    assert llm.calls == 0


def test_an_unsafe_check_in_is_replaced_and_flagged():
    db = make_open_db(event_type="sauna")
    llm = FakeLLM("This is a diagnosis of atrial fibrillation.")

    run_in_progress(db, llm)

    row = db.tables["predictions"][0]
    assert "diagnosis" not in row["summary"].lower()
    assert "atrial" not in row["summary"].lower()
    assert "diagnosis" in row["guardrail_flags"]


def test_a_check_in_without_an_llm_still_reaches_the_user():
    db = make_open_db(event_type="sauna")

    run_in_progress(db, None)

    row = db.tables["predictions"][0]
    assert "in progress" in row["summary"].lower()


def test_a_check_before_the_min_elapsed_guard_stays_silent():
    db, llm = make_open_db(event_type="sauna"), FakeLLM()

    run_in_progress(db, llm, now=START + timedelta(minutes=5))

    assert db.tables.get("predictions", []) == []
    assert llm.calls == 0


def test_in_progress_does_not_mutate_the_user_id():
    db = make_open_db(event_type="sauna")

    result = run_in_progress(db, FakeLLM())

    assert result["user_id"] == ALICE


class CountingLoader(ContextLoader):
    """Counts the expensive read so a test can prove it was skipped."""

    def __init__(self, db):
        super().__init__(db)
        self.reading_loads = 0

    def load_readings(self, user_id, start, end):
        self.reading_loads += 1
        return super().load_readings(user_id, start, end)


def test_all_reasons_delivered_skips_the_fourteen_day_reading_load():
    """Every check re-reads 14 days of raw measurements to build the baseline.
    Once there is nothing left that could fire, that read buys nothing."""
    db = make_open_db(event_type="sauna")
    db.tables["predictions"] = [
        {"user_id": ALICE, "event_id": EVENT_ID, "kind": f"check_in:{reason}",
         "summary": "already said"}
        for reason in PRIORITY
    ]
    loader = CountingLoader(db)

    build_agent(loader, FakeLLM(), db).invoke({
        "user_id": ALICE, "event_id": EVENT_ID,
        "status": "in_progress", "now": IN_PROGRESS_NOW.isoformat(),
    })

    assert loader.reading_loads == 0


def test_a_check_with_reasons_still_available_does_load_readings():
    db = make_open_db(event_type="sauna")
    loader = CountingLoader(db)

    build_agent(loader, FakeLLM(), db).invoke({
        "user_id": ALICE, "event_id": EVENT_ID,
        "status": "in_progress", "now": IN_PROGRESS_NOW.isoformat(),
    })

    assert loader.reading_loads == 1


def test_a_flagged_check_in_keeps_the_fired_fact_instead_of_going_generic():
    """A fired rule must never reach the user as a generic clinician message: the
    deterministic fact was computed from their own numbers and is safe by
    construction, so it is the right fallback when the wording is rejected."""
    db = make_open_db(event_type="sauna")
    llm = FakeLLM("This is a diagnosis of atrial fibrillation.")

    run_in_progress(db, llm)

    row = db.tables["predictions"][0]
    assert "diagnosis" in row["guardrail_flags"]
    assert "in progress" in row["summary"].lower()
    assert "bpm" in row["summary"]
