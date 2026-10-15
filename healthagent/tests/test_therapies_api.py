"""The therapy evidence REST surface."""

from datetime import datetime, timedelta, timezone

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.analytics.therapy_effect import MODEL_VERSION
from app.common.supabase_client import get_supabase_client
from app.gateway.api.therapies import router
from app.gateway.auth import current_user_id
from tests.fakes import FakeSupabase

UTC = timezone.utc
ALICE = "00000000-0000-0000-0000-00000000000a"
BOB = "00000000-0000-0000-0000-00000000000b"
BASE = datetime.now(UTC) - timedelta(days=1)


def db_with_sessions(user_id=ALICE, count=8):
    events, measurements = [], []
    for index in range(count):
        start = BASE - timedelta(days=index * 3)
        end = start + timedelta(minutes=20)
        events.append({
            "id": f"s{index}", "user_id": user_id, "event_type": "sauna",
            "status": "ended", "started_at": start.isoformat(),
            "ended_at": end.isoformat(),
        })
        for stamp, value in (
            (start - timedelta(minutes=30), 60),
            (end + timedelta(minutes=30), 77),
        ):
            measurements.append({
                "user_id": user_id, "measurement_type": "heartRate",
                "value": value, "recorded_at": stamp.isoformat(),
            })
    return FakeSupabase({"events": events, "health_measurements": measurements})


def client_for(db, user_id=ALICE):
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[current_user_id] = lambda: user_id
    app.dependency_overrides[get_supabase_client] = lambda: db
    return TestClient(app)


def test_a_run_of_sessions_comes_back_with_its_provenance():
    response = client_for(db_with_sessions()).get("/api/v1/therapies/effects")

    assert response.status_code == 200
    body = response.json()
    assert body["model_version"] == MODEL_VERSION
    assert body["catalog_version"]
    assert body["verdicts"][0]["verdict"] == "helped"
    reported = [r for r in body["reported"] if r["metric"] == "heartRate"]
    assert reported[0]["modality"] == "sauna"
    assert reported[0]["sessions"] == 8


def test_an_unsigned_mechanism_does_not_reach_the_screen():
    body = client_for(db_with_sessions()).get("/api/v1/therapies/effects").json()

    assert body["reported"][0]["mechanism"] is None
    assert body["reported"][0]["mechanism_reviewed"] is False


def test_another_users_sessions_are_not_reachable():
    response = client_for(db_with_sessions(user_id=BOB), user_id=ALICE).get(
        "/api/v1/therapies/effects"
    )

    assert response.json()["reported"] == []


def test_three_sessions_is_a_result_and_not_an_error():
    response = client_for(db_with_sessions(count=3)).get("/api/v1/therapies/effects")

    assert response.status_code == 200
    body = response.json()
    assert body["reported"] == []
    assert body["withheld"][0]["withheld"] == "too_few_sessions"


def test_no_sessions_at_all_is_still_a_two_hundred():
    response = client_for(FakeSupabase({"events": [], "health_measurements": []})).get(
        "/api/v1/therapies/effects"
    )

    assert response.status_code == 200
    assert response.json()["tested"] == 0


def test_a_window_the_engine_cannot_use_is_refused():
    response = client_for(db_with_sessions()).get("/api/v1/therapies/effects?days=3")

    assert response.status_code == 422
