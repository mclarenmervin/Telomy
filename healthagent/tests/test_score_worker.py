"""The worker that turns a scheduled job into a stored score."""

from datetime import datetime, timedelta, timezone

from app.score_worker.handlers import process_score_job
from tests.fakes import FakeSupabase

UTC = timezone.utc
ALICE = "00000000-0000-0000-0000-00000000000a"


def scorable_db(user_id=ALICE):
    day = datetime(2026, 10, 1, tzinfo=UTC)
    rows = []
    for offset in range(1, 31):
        at = day - timedelta(days=offset)
        rows += [
            {"user_id": user_id, "measurement_type": "hrv", "value": 55,
             "recorded_at": at.isoformat()},
            {"user_id": user_id, "measurement_type": "restingHeartRate", "value": 60,
             "recorded_at": at.isoformat()},
        ]
    rows += [
        {"user_id": user_id, "measurement_type": "hrv", "value": 60,
         "recorded_at": (day + timedelta(hours=7)).isoformat()},
        {"user_id": user_id, "measurement_type": "stress", "value": 30,
         "recorded_at": (day + timedelta(hours=10)).isoformat()},
    ]
    return FakeSupabase({
        "health_measurements": rows,
        "user_preferences": [{"user_id": user_id, "profile": {}}],
    })


JOB = {"kind": "score_recompute", "user_id": ALICE, "as_of": "2026-10-01"}


def test_a_job_stores_a_snapshot():
    db = scorable_db()

    process_score_job(JOB, db)

    rows = db.tables["score_snapshots"]
    assert len(rows) == 1
    assert rows[0]["score_kind"] == "readiness"
    assert rows[0]["as_of_date"] == "2026-10-01"


def test_rerunning_the_same_job_replaces_rather_than_duplicates():
    db = scorable_db()

    process_score_job(JOB, db)
    process_score_job(JOB, db)

    assert len(db.tables["score_snapshots"]) == 1


def test_a_day_with_no_data_still_records_that_we_looked():
    """An absent score and an unrecorded day are different; the first is an
    answer, the second is a gap in our own processing."""
    db = FakeSupabase({"health_measurements": [],
                       "user_preferences": [{"user_id": ALICE, "profile": {}}]})

    process_score_job(JOB, db)

    assert db.tables["score_snapshots"][0]["data_quality"] == "none"


def test_a_malformed_job_does_not_raise():
    process_score_job({}, scorable_db())
    process_score_job({"user_id": ALICE}, scorable_db())
    process_score_job({"user_id": ALICE, "as_of": "not-a-date"}, scorable_db())


def test_a_failing_database_does_not_raise():
    class Boom:
        def table(self, name):
            raise ConnectionError("supabase down")

    process_score_job(JOB, Boom())


def test_an_unknown_job_kind_is_ignored():
    db = scorable_db()

    process_score_job({**JOB, "kind": "something_else"}, db)

    assert db.tables.get("score_snapshots", []) == []
