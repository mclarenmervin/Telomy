"""The environment REST surface.

It exists at all because the AQI and UV bands are computed. Everything else
on this screen could have been a direct table read, like scores and chat
history are — but a band computed on the phone would be a second
implementation of a published scale, and the two would disagree the first
time a breakpoint moved.
"""

from datetime import date, timedelta

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.common.supabase_client import get_supabase_client
from app.gateway.api.environment import router
from app.gateway.auth import current_user_id
from tests.fakes import FakeSupabase

ALICE = "00000000-0000-0000-0000-00000000000a"
BOB = "00000000-0000-0000-0000-00000000000b"


def snapshot(user_id=ALICE, days_ago=1, us_aqi_max=181.0, uv=9.4, hours=24):
    return {
        "user_id": user_id,
        "observed_on": (date.today() - timedelta(days=days_ago)).isoformat(),
        "latitude": 13.0,
        "longitude": 77.6,
        "us_aqi_mean": 92.0,
        "us_aqi_max": us_aqi_max,
        "european_aqi_mean": 55.0,
        "pm2_5_mean": 40.0,
        "pm10_mean": 60.0,
        "uv_index_max": uv,
        "hours_observed": hours,
        "provider": "open-meteo",
    }


def client_for(db, user_id=ALICE):
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[current_user_id] = lambda: user_id
    app.dependency_overrides[get_supabase_client] = lambda: db
    return TestClient(app)


def test_a_day_comes_back_with_its_bands_and_its_provider():
    db = FakeSupabase({"environment_snapshots": [snapshot()]})

    response = client_for(db).get("/api/v1/environment")

    assert response.status_code == 200
    item = response.json()["items"][0]
    assert item["us_aqi_band"] == "unhealthy"
    assert item["uv_band"] == "very high"
    assert item["provider"] == "open-meteo"


def test_the_band_comes_from_the_peak_and_not_the_average():
    """A day that averaged 92 and peaked at 181 is an unhealthy day."""
    db = FakeSupabase({"environment_snapshots": [snapshot()]})

    item = client_for(db).get("/api/v1/environment").json()["items"][0]

    assert item["us_aqi_mean"] == 92.0
    assert item["us_aqi_band"] == "unhealthy"


def test_another_users_days_are_not_reachable():
    db = FakeSupabase({"environment_snapshots": [snapshot(user_id=BOB)]})

    response = client_for(db, user_id=ALICE).get("/api/v1/environment")

    assert response.json()["items"] == []


def test_no_location_is_empty_rather_than_clean_air():
    """Almost every user is in this state, and it means "we have no
    location", not "the air was fine"."""
    db = FakeSupabase({"environment_snapshots": []})

    response = client_for(db).get("/api/v1/environment")

    assert response.status_code == 200
    assert response.json()["status"] == "empty"


def test_a_partial_day_carries_how_much_of_it_was_seen():
    db = FakeSupabase({"environment_snapshots": [snapshot(hours=4)]})

    item = client_for(db).get("/api/v1/environment").json()["items"][0]

    assert item["hours_observed"] == 4


def test_a_window_longer_than_the_engine_keeps_is_refused():
    db = FakeSupabase({"environment_snapshots": [snapshot()]})

    assert client_for(db).get("/api/v1/environment?days=3650").status_code == 422
