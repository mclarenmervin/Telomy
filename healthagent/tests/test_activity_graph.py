
from app.activity_agent.agent import build_activity_agent
from app.common.context_loader import ContextLoader
from tests.fakes import FakeSupabase, make_settings

USER = "user-1"
SESSION = {
    "id": "s1", "user_id": USER, "activity_type": "running",
    "started_at": "2026-09-29T06:00:00+00:00", "duration_seconds": 1800,
    "summary": {"heartRate": 142}, "samples": [{"heartRate": 142}] * 60,
}
PAST = [
    {"id": f"p{i}", "user_id": USER, "activity_type": "running",
     "started_at": f"2026-09-2{i}T06:00:00+00:00", "duration_seconds": 1800,
     "summary": {"heartRate": 150}}
    for i in range(1, 4)
]
SETTINGS = make_settings(openai_api_key=None, llm_model="x")


def _invoke(db, session_id="s1", user_id=USER):
    agent = build_activity_agent(ContextLoader(db), db, SETTINGS, checkpointer=None)
    return agent.invoke(
        {"messages": []},
        context={"user_id": user_id, "session_id": session_id},
        config={"configurable": {"thread_id": session_id}},
    )


def test_report_is_written_without_an_llm_using_the_fallback():
    db = FakeSupabase({"activity_sessions": [SESSION] + PAST, "predictions": []})
    _invoke(db)
    rows = db.tables["predictions"]
    assert len(rows) == 1
    assert rows[0]["kind"] == "activity_summary"
    assert rows[0]["analysis"]["score"]["value"] > 0
    assert len(rows[0]["analysis"]["sections"]) == 5
    assert rows[0]["summary"]


def test_another_users_session_writes_nothing():
    db = FakeSupabase({"activity_sessions": [SESSION], "predictions": []})
    _invoke(db, user_id="user-2")
    assert db.tables["predictions"] == []


def test_accidental_tap_writes_nothing():
    db = FakeSupabase(
        {"activity_sessions": [dict(SESSION, duration_seconds=4)], "predictions": []}
    )
    _invoke(db)
    assert db.tables["predictions"] == []


def test_repeat_delivery_does_not_duplicate():
    db = FakeSupabase({"activity_sessions": [SESSION] + PAST, "predictions": []})
    _invoke(db)
    _invoke(db)
    assert len(db.tables["predictions"]) == 1


def test_data_gaps_reach_the_persisted_report():
    db = FakeSupabase({"activity_sessions": [SESSION] + PAST, "predictions": []})
    _invoke(db)
    gaps = {g["source"]: g["status"] for g in db.tables["predictions"][0]["analysis"]["data_gaps"]}
    assert gaps["documents"] == "unconfigured"
