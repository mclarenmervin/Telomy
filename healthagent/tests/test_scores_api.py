"""The scores REST surface.

Two properties are the point:

1. The caller is taken from the verified token and never from the request, so a
   user cannot ask for someone else's scores by editing a parameter.
2. The handler calls the same function the worker and the agent call, so a
   chart and a sentence cannot disagree about the same number.
"""

from datetime import date, datetime, timedelta, timezone

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from app.gateway.api.scores import router
from app.gateway.auth import current_user_id
from app.common.supabase_client import get_supabase_client
from tests.fakes import FakeSupabase

UTC = timezone.utc
ALICE = "00000000-0000-0000-0000-00000000000a"
BOB = "00000000-0000-0000-0000-00000000000b"


def db_with_snapshot(user_id=ALICE, as_of="2026-10-01", value=72):
    return FakeSupabase({"score_snapshots": [{
        "user_id": user_id, "score_kind": "readiness", "as_of_date": as_of,
        "value": value, "drivers": [{"name": "HRV", "score": 80.0, "weight": 0.22}],
        "missing_inputs": [], "data_quality": "full",
        "model_version": "readiness-v1", "ranges_version": None,
        "timezone": "Asia/Kolkata", "inputs_hash": "sha256:abc",
        "computed_at": "2026-10-02T03:00:00",
    }]})


def client_for(db, user_id=ALICE):
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[current_user_id] = lambda: user_id
    app.dependency_overrides[get_supabase_client] = lambda: db
    return TestClient(app)


def test_the_latest_score_is_returned_with_its_provenance():
    response = client_for(db_with_snapshot()).get("/api/v1/scores/readiness")

    assert response.status_code == 200
    body = response.json()
    assert body["value"] == 72
    assert body["model_version"] == "readiness-v1"
    assert body["timezone"] == "Asia/Kolkata"
    assert body["data_quality"] == "full"
    assert body["inputs_hash"] == "sha256:abc"


def test_drivers_come_back_so_the_screen_renders_rather_than_recomputes():
    body = client_for(db_with_snapshot()).get("/api/v1/scores/readiness").json()

    assert body["drivers"][0]["name"] == "HRV"


def test_another_users_snapshot_is_never_returned():
    """The identity comes from the token; there is no parameter to tamper with."""
    response = client_for(db_with_snapshot(user_id=BOB), user_id=ALICE).get(
        "/api/v1/scores/readiness")

    assert response.status_code == 404


def test_a_specific_day_can_be_requested():
    db = db_with_snapshot(as_of="2026-09-28", value=51)
    db.tables["score_snapshots"].append({
        **db.tables["score_snapshots"][0], "as_of_date": "2026-10-01", "value": 72})

    body = client_for(db).get("/api/v1/scores/readiness?as_of=2026-09-28").json()

    assert body["value"] == 51


def test_the_most_recent_day_is_returned_when_none_is_asked_for():
    db = db_with_snapshot(as_of="2026-09-28", value=51)
    db.tables["score_snapshots"].append({
        **db.tables["score_snapshots"][0], "as_of_date": "2026-10-01", "value": 72})

    body = client_for(db).get("/api/v1/scores/readiness").json()

    assert body["value"] == 72


def test_no_snapshot_yet_is_a_404_not_an_invented_zero():
    response = client_for(FakeSupabase({})).get("/api/v1/scores/readiness")

    assert response.status_code == 404


def test_an_unknown_score_kind_is_rejected():
    response = client_for(db_with_snapshot()).get("/api/v1/scores/horoscope")

    assert response.status_code == 422


def test_a_malformed_date_is_rejected_rather_than_ignored():
    response = client_for(db_with_snapshot()).get("/api/v1/scores/readiness?as_of=soon")

    assert response.status_code == 422


def test_an_unauthenticated_request_is_refused():
    """Without the dependency override, the real verifier runs."""
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[get_supabase_client] = lambda: db_with_snapshot()

    assert TestClient(app).get("/api/v1/scores/readiness").status_code == 401


def test_recompute_now_computes_stores_and_returns_a_fresh_score():
    """What the app calls after the user confirms new data, rather than waiting
    for tonight's sweep."""
    day = datetime(2026, 10, 1, tzinfo=UTC)
    rows = []
    for offset in range(1, 31):
        at = day - timedelta(days=offset)
        rows += [
            {"user_id": ALICE, "measurement_type": "hrv", "value": 55,
             "recorded_at": at.isoformat()},
            {"user_id": ALICE, "measurement_type": "restingHeartRate", "value": 60,
             "recorded_at": at.isoformat()},
        ]
    rows += [
        {"user_id": ALICE, "measurement_type": "hrv", "value": 60,
         "recorded_at": (day + timedelta(hours=7)).isoformat()},
        {"user_id": ALICE, "measurement_type": "stress", "value": 30,
         "recorded_at": (day + timedelta(hours=10)).isoformat()},
    ]
    db = FakeSupabase({
        "health_measurements": rows,
        "user_preferences": [{"user_id": ALICE, "profile": {}}],
    })

    response = client_for(db).post("/api/v1/scores/readiness/recompute?as_of=2026-10-01")

    assert response.status_code == 200
    assert response.json()["value"] is not None
    assert len(db.tables["score_snapshots"]) == 1


# ── Biological age ───────────────────────────────────────────────────────────

def bio_age_db(user_id=ALICE):
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
        "score_snapshots": [],
    })


def test_biological_age_can_be_recomputed_on_request():
    """"I have just confirmed my labs and should not wait for tonight's sweep"
    is the whole reason this endpoint exists alongside the table read."""
    db = bio_age_db()

    response = client_for(db).post(
        "/api/v1/scores/biological_age/recompute?as_of=2026-10-08"
    )

    assert response.status_code == 200
    assert response.json()["score_kind"] == "biological_age"


def test_a_recomputed_biological_age_is_dated_to_the_draw():
    db = bio_age_db()

    body = client_for(db).post(
        "/api/v1/scores/biological_age/recompute?as_of=2026-10-08"
    ).json()

    assert body["as_of_date"] == "2026-06-15"


def test_a_stored_biological_age_is_readable():
    db = FakeSupabase({"score_snapshots": [{
        "user_id": ALICE, "score_kind": "biological_age", "as_of_date": "2026-06-15",
        "value": 43.2, "drivers": [], "missing_inputs": [], "data_quality": "full",
        "model_version": "biological-age-phenoage-levine-2018-v1",
        "ranges_version": "global.v1", "timezone": "Asia/Kolkata",
        "inputs_hash": "sha256:abc", "computed_at": "2026-06-16T03:00:00",
    }]})

    body = client_for(db).get("/api/v1/scores/biological_age").json()

    assert body["value"] == 43.2
    assert body["ranges_version"] == "global.v1"


def test_a_score_kind_with_no_implementation_is_refused_by_the_schema():
    """`score_snapshots` permits five kinds in its check constraint and two are
    implemented. Asking for an unimplemented one must be a 422, not a 500 and
    not an empty result that reads as "you have no score"."""
    response = client_for(bio_age_db()).post(
        "/api/v1/scores/longi/recompute?as_of=2026-10-08"
    )

    assert response.status_code == 422
