from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.common.supabase_client import get_supabase_client
from app.gateway.api.therapies import router
from app.gateway.auth import current_user_id
from tests.fakes import FakeSupabase

USER = "10000000-0000-4000-8000-000000000001"
CENTRE = "20000000-0000-4000-8000-000000000001"


def client(store, user=USER):
    app = FastAPI(); app.include_router(router)
    app.dependency_overrides[current_user_id] = lambda: user
    app.dependency_overrides[get_supabase_client] = lambda: store
    return TestClient(app)


def test_catalogue_and_scoped_offerings_use_indicative_price_language():
    store = FakeSupabase({
        "therapy_catalogue": [{"id": "cat-1", "slug": "sauna", "display_name": "Sauna",
                               "summary": "Dry heat session", "publication_status": "published"}],
        "centre_memberships": [{"centre_id": CENTRE, "user_id": USER, "status": "active", "left_at": None}],
        "centre_therapy_offerings": [{"id": "offer-1", "centre_id": CENTRE, "catalogue_id": "cat-1",
                                      "status": "active", "indicative_price_minor": 150000,
                                      "currency_code": "INR"}],
    })
    assert client(store).get("/api/v1/therapies/catalogue").json()["items"][0]["slug"] == "sauna"
    offering = client(store).get(f"/api/v1/therapies/centres/{CENTRE}/offerings").json()["items"][0]
    assert offering["price_qualifier"] == "Indicative"
    assert offering["catalogue"]["slug"] == "sauna"


def test_cross_centre_offerings_return_no_rows():
    store = FakeSupabase({"centre_memberships": [], "centre_therapy_offerings": []})
    response = client(store).get(f"/api/v1/therapies/centres/{CENTRE}/offerings")
    assert response.status_code == 404
