from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.common.supabase_client import get_supabase_client
from app.gateway.api.therapies import router
from app.gateway.auth import current_user_id
from tests.test_therapy_plans import CENTRE, PATIENT, SAFE, db, items


def client(store, user=PATIENT):
    app = FastAPI(); app.include_router(router)
    app.dependency_overrides[current_user_id] = lambda: user
    app.dependency_overrides[get_supabase_client] = lambda: store
    return TestClient(app)


def test_patient_proposes_and_reads_only_their_own_plan(monkeypatch):
    store = db()
    monkeypatch.setattr("app.gateway.api.therapies.ContextLoader.therapy_safety_facts", lambda self, user_id: SAFE)
    created = client(store).post("/api/v1/therapies/plans", json={"centre_id": CENTRE, "items": items()})
    assert created.status_code == 201
    assert created.json()["patient_id"] == PATIENT
    listed = client(store).get("/api/v1/therapies/plans").json()["items"]
    assert [row["id"] for row in listed] == [created.json()["id"]]


def test_patient_cannot_nominate_a_different_plan_owner(monkeypatch):
    store = db()
    monkeypatch.setattr("app.gateway.api.therapies.ContextLoader.therapy_safety_facts", lambda self, user_id: SAFE)
    body = {"centre_id": CENTRE, "patient_id": "someone-else", "items": items()}
    response = client(store).post("/api/v1/therapies/plans", json=body)
    assert response.status_code == 422
