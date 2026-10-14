from types import SimpleNamespace

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from app.gateway.api.admin_centre_operations import (
    AdminOperationsScope,
    admin_create_booking,
    admin_create_room,
    admin_transition_booking,
    router,
)
from app.gateway.api.centre import BookingCreate, BookingTransition, RoomCreate, operational_transition_booking
from app.gateway.auth import current_user_id
from app.common.supabase_client import get_supabase_client
from tests.fakes import FakeSupabase


ADMIN = "10000000-0000-0000-0000-0000000000ad"
CENTRE_A = "20000000-0000-0000-0000-000000000001"
CENTRE_B = "20000000-0000-0000-0000-000000000002"


class Db:
    def __init__(self):
        self.calls = []
        self.centres = {CENTRE_A, CENTRE_B}

    def table(self, name):
        if name == "centres":
            rows = [{"id": centre, "status": "active"} for centre in self.centres]
        elif name == "centre_bookings":
            rows = [
                {"id": "booking-1", "centre_id": centre, "status": "booked", "version": 0}
                for centre in self.centres
            ]
        else:
            rows = []
        return Query(rows)

    def rpc(self, name, params):
        self.calls.append((name, params))
        return SimpleNamespace(execute=lambda: SimpleNamespace(data={
            "create_centre_room": "room-1",
            "create_centre_booking": "booking-1",
            "transition_centre_booking": "booking-1",
        }.get(name)))


class Query:
    def __init__(self, rows): self.rows, self.filters = rows, []
    def select(self, *_args): return self
    def eq(self, key, value): self.filters.append((key, value)); return self
    def limit(self, _value): return self
    def execute(self): return SimpleNamespace(data=[row for row in self.rows if all(row.get(key) == value for key, value in self.filters)])


def test_admin_can_operate_either_active_centre():
    db = Db()
    for centre in (CENTRE_A, CENTRE_B):
        scope = AdminOperationsScope(ADMIN, centre)
        assert admin_create_room(RoomCreate(name="Room"), scope, db)["id"] == "room-1"
        assert db.calls[-1][1]["p_centre"] == centre


def test_admin_operational_surface_only_calls_operational_procedures():
    db = Db()
    scope = AdminOperationsScope(ADMIN, CENTRE_A)
    admin_create_room(RoomCreate(name="Room"), scope, db)
    admin_create_booking(BookingCreate(patient_id="patient", service_id="service", room_id="room", scheduled_start="2026-10-19T09:00:00Z"), scope, db)
    operational_transition_booking("booking", BookingTransition(command="cancel", expected_version=0), scope.centre_scope(), db, verify_scoped=False)
    assert {name for name, _ in db.calls} <= {
        "create_centre_room", "create_centre_booking", "transition_centre_booking"
    }


def test_admin_foreign_centre_is_not_found():
    db = Db()
    with pytest.raises(HTTPException) as error:
        AdminOperationsScope.resolve(ADMIN, "foreign", db)
    assert error.value.status_code == 404


class ApiDb(FakeSupabase):
    def __init__(self, role="admin"):
        super().__init__({
            "profiles": [{"id": ADMIN, "app_role": role}],
            "centres": [{"id": CENTRE_A, "status": "active"}, {"id": CENTRE_B, "status": "active"}],
            "centre_rooms": [], "centre_room_hours": [], "centre_services": [],
            "centre_room_services": [], "centre_bookings": [],
            "clinical_access_consents": [],
        })


def client_for(db):
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[current_user_id] = lambda: ADMIN
    app.dependency_overrides[get_supabase_client] = lambda: db
    return TestClient(app)


def test_admin_routes_require_database_admin_role_and_support_both_centres():
    assert client_for(ApiDb(role="member")).get(f"/api/v1/admin/centres/{CENTRE_A}/operations/rooms").status_code == 403
    client = client_for(ApiDb())
    assert client.get(f"/api/v1/admin/centres/{CENTRE_A}/operations/rooms").status_code == 200
    assert client.get(f"/api/v1/admin/centres/{CENTRE_B}/operations/rooms").status_code == 200


def test_admin_operations_have_no_clinical_mutation_route():
    client = client_for(ApiDb())
    response = client.post(f"/api/v1/admin/centres/{CENTRE_A}/operations/patients/patient/clinical-record", json={})
    assert response.status_code == 404
