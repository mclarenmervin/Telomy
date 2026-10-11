"""The correlations REST surface.

Two properties, the same two the scores router exists to hold:

1. The caller is taken from the verified token and never from the request.
2. The handler calls the same function the agent's tool calls, so a card and
   a sentence cannot disagree about the same two series.
"""

from datetime import datetime, timedelta, timezone

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.analytics.correlations import MODEL_VERSION
from app.common.supabase_client import get_supabase_client
from app.gateway.api.correlations import router
from app.gateway.auth import current_user_id
from tests.fakes import FakeSupabase

UTC = timezone.utc
ALICE = "00000000-0000-0000-0000-00000000000a"
BOB = "00000000-0000-0000-0000-00000000000b"


def reading(user_id, measurement_type, value, days_ago):
    return {
        "user_id": user_id,
        "measurement_type": measurement_type,
        "value": value,
        "recorded_at": (datetime.now(UTC) - timedelta(days=days_ago)).isoformat(),
    }


def db_with_a_pattern(user_id=ALICE):
    rows = []
    for day in range(40):
        swing = (day % 7) * 3
        rows.append(reading(user_id, "hrv", 40 + swing, day))
        rows.append(reading(user_id, "restingHeartRate", 70 - swing, day))
    return FakeSupabase({
        "health_measurements": rows,
        "meals": [], "workouts": [], "hydration_logs": [],
    })


def client_for(db, user_id=ALICE):
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[current_user_id] = lambda: user_id
    app.dependency_overrides[get_supabase_client] = lambda: db
    return TestClient(app)


def test_a_pattern_comes_back_with_its_provenance():
    response = client_for(db_with_a_pattern()).get("/api/v1/correlations")

    assert response.status_code == 200
    body = response.json()
    assert body["model_version"] == MODEL_VERSION
    assert body["pairs_version"]
    assert [r["pair_id"] for r in body["reported"]] == ["hrv__resting_heart_rate"]


def test_another_users_days_are_not_reachable():
    """The isolation, exercised: the rows belong to Bob and Alice is asking."""
    response = client_for(db_with_a_pattern(user_id=BOB), user_id=ALICE).get(
        "/api/v1/correlations"
    )

    assert response.status_code == 200
    assert response.json()["reported"] == []


def test_nothing_reportable_is_still_a_two_hundred():
    """"We tested five pairs and none held" is a result the screen has to be
    able to render. A 404 would have it say the feature is broken."""
    db = FakeSupabase({
        "health_measurements": [], "meals": [], "workouts": [], "hydration_logs": [],
    })

    response = client_for(db).get("/api/v1/correlations")

    assert response.status_code == 200
    assert response.json()["tested"] == 0


def test_a_window_shorter_than_the_engine_can_use_is_refused():
    """Offering a button that can only ever produce "nothing found" is worse
    than not offering it."""
    response = client_for(db_with_a_pattern()).get("/api/v1/correlations?days=7")

    assert response.status_code == 422


def test_a_window_longer_than_the_engine_supports_is_refused():
    response = client_for(db_with_a_pattern()).get("/api/v1/correlations?days=3650")

    assert response.status_code == 422


def test_the_window_is_reported_back_as_the_one_used():
    response = client_for(db_with_a_pattern()).get("/api/v1/correlations?days=30")

    assert response.json()["window_days"] == 30
