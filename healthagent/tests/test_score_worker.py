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


# ── Which score a job computes ───────────────────────────────────────────────
#
# Bite 12 of the F4 handoff, made concrete. Readiness reads heartRate, hrv,
# temperature and spo2 -- no lab marker at all -- so before this, confirming a
# panel enqueued a recompute that could not change a single number. The job now
# says which score it is for, and a confirmation enqueues one per kind.

BIO_JOB = {"kind": "score_recompute", "user_id": ALICE,
           "as_of": "2026-06-15", "score_kind": "biological_age"}


def lab_db(user_id=ALICE):
    units = {"albumin": "g/dL", "creatinine": "mg/dL", "glucose_fasting": "mg/dL",
             "hs_crp": "mg/L", "lymphocyte_percent": "%", "mcv": "fL", "rdw": "%",
             "alkaline_phosphatase": "U/L", "wbc": "10^3/uL"}
    values = {"albumin": 4.2, "creatinine": 0.96, "glucose_fasting": 97.0,
              "hs_crp": 1.5, "lymphocyte_percent": 28.0, "mcv": 90.0,
              "rdw": 13.5, "alkaline_phosphatase": 75.0, "wbc": 6.8}
    return FakeSupabase({
        "biomarker_results": [
            {"user_id": user_id, "biomarker_id": marker, "value_canonical": value,
             "unit_canonical": units[marker], "value_text": None,
             "result_type": "quantitative", "operator": "=", "status": "confirmed",
             "context": "fasting" if marker == "glucose_fasting" else "standard",
             "collected_at": "2026-06-15T07:30:00+00:00", "lab_name": "Lab"}
            for marker, value in values.items()
        ],
        "user_preferences": [{"user_id": user_id, "profile": {"dob": "1981-02-10"}}],
    })


def test_a_job_can_ask_for_biological_age():
    db = lab_db()

    process_score_job(BIO_JOB, db)

    rows = db.tables["score_snapshots"]
    assert len(rows) == 1
    assert rows[0]["score_kind"] == "biological_age"


def test_a_biological_age_job_is_dated_to_the_draw_not_to_the_job():
    """The job carries the date the user confirmed the upload; the snapshot
    belongs to the day the blood was taken."""
    db = lab_db()

    process_score_job({**BIO_JOB, "as_of": "2026-10-08"}, db)

    assert db.tables["score_snapshots"][0]["as_of_date"] == "2026-06-15"


def test_a_job_with_no_score_kind_still_computes_readiness():
    """Jobs already on the queue when this deployed carry no score_kind, and a
    queue is not drained at deploy time."""
    db = scorable_db()

    process_score_job(JOB, db)

    assert db.tables["score_snapshots"][0]["score_kind"] == "readiness"


def test_a_job_naming_a_score_we_do_not_compute_is_ignored_not_crashed():
    db = scorable_db()

    process_score_job({**JOB, "score_kind": "longi"}, db)

    assert db.tables.get("score_snapshots", []) == []
