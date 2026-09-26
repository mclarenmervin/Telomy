from app.agent.persist import save_prediction
from tests.fakes import FakeSupabase

USER = "00000000-0000-0000-0000-00000000000a"


def prediction(summary="first", kind="analysis"):
    return {
        "user_id": USER,
        "event_id": "11111111-1111-1111-1111-111111111111",
        "kind": kind,
        "summary": summary,
        "analysis": {"data_quality": "full"},
        "data_quality": "full",
        "guardrail_flags": [],
    }


def test_save_prediction_writes_a_row():
    db = FakeSupabase()

    save_prediction(db, prediction())

    rows = db.tables["predictions"]
    assert len(rows) == 1
    assert rows[0]["summary"] == "first"


def test_saving_the_same_event_and_kind_twice_keeps_one_row():
    db = FakeSupabase()

    save_prediction(db, prediction("first"))
    save_prediction(db, prediction("second"))

    rows = db.tables["predictions"]
    assert len(rows) == 1
    assert rows[0]["summary"] == "second"


def test_ack_and_analysis_are_separate_rows():
    db = FakeSupabase()

    save_prediction(db, prediction(kind="ack"))
    save_prediction(db, prediction(kind="analysis"))

    assert len(db.tables["predictions"]) == 2
