from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.common.supabase_client import get_supabase_client
from app.gateway.api.therapy_sessions import router
from app.gateway.auth import current_user_id
from tests.test_therapy_sessions import PATIENT, SAFE, db


def client(store):
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[current_user_id] = lambda: PATIENT
    app.dependency_overrides[get_supabase_client] = lambda: store
    return TestClient(app)


def test_patient_books_starts_and_finishes_their_session(monkeypatch):
    store = db()
    monkeypatch.setattr("app.gateway.api.therapy_sessions.ContextLoader.therapy_safety_facts", lambda self, user_id: SAFE)
    created = client(store).post("/api/v1/therapy-sessions", json={
        "plan_item_id": "item-1", "offering_id": "offer-1",
        "scheduled_start": "2026-10-20T10:00:00Z",
    }, headers={"Idempotency-Key": "api-book-1"})
    assert created.status_code == 201
    session_id = created.json()["id"]
    assert client(store).post(f"/api/v1/therapy-sessions/{session_id}/start").status_code == 200
    finished = client(store).post(f"/api/v1/therapy-sessions/{session_id}/finish",
                                  json={"delivered_dose": {"duration_minutes": 18}})
    assert finished.status_code == 200
    assert finished.json()["reconciliation_state"] == "emitted"


def test_patient_cannot_address_another_patients_session(monkeypatch):
    store = db()
    store.tables["therapy_service_sessions"].append({"id": "foreign", "patient_id": "other", "status": "scheduled"})
    monkeypatch.setattr("app.gateway.api.therapy_sessions.ContextLoader.therapy_safety_facts", lambda self, user_id: SAFE)
    assert client(store).post("/api/v1/therapy-sessions/foreign/start").status_code == 403
