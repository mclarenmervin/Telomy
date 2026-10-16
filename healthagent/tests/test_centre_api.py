from types import SimpleNamespace

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from app.gateway.api.centre import (
    AssignmentCreate,
    BookingCreate,
    BookingTransition,
    RoomCreate,
    RoomHoursCreate,
    ServiceCreate,
    StatusUpdate,
    TherapyOfferingCreate,
    assign_patient,
    create_booking,
    create_room,
    create_room_hours,
    create_service,
    end_room_hours,
    link_room_service,
    unlink_room_service,
    list_bookings,
    list_members,
    read_centre_clinical_record,
    transition_booking,
    create_therapy_offering,
)
from app.gateway import tenancy
from app.gateway.api.centre import router
from app.gateway.auth import current_user_id
from app.common.supabase_client import get_supabase_client
from tests.fakes import FakeSupabase


OWNER = "10000000-0000-0000-0000-000000000001"
DOCTOR = "10000000-0000-0000-0000-000000000002"
PATIENT = "10000000-0000-0000-0000-000000000003"
CENTRE = "20000000-0000-0000-0000-000000000001"
MEMBERSHIP = "30000000-0000-0000-0000-000000000001"


def owner_scope():
    scope_type = getattr(tenancy, "CentreOwnerScope", None)
    assert scope_type is not None, "CentreOwnerScope is missing"
    return scope_type(
        actor_id=OWNER,
        membership_id=MEMBERSHIP,
        centre_id=CENTRE,
    )


class Db:
    def __init__(self, consent=True, audit_fails=False):
        self.calls = []
        self.consent = consent
        self.audit_fails = audit_fails
        self.rpc_values = {}
        self.tables = {}

    def rpc(self, name, params):
        self.calls.append((name, params))
        if name == "record_access_event" and self.audit_fails:
            raise RuntimeError("audit unavailable")
        values = {
            "active_centre_membership": True,
            "centre_can_read_clinical": self.consent,
            "assign_patient_doctor": "assignment-1",
            "record_access_event": "audit-1",
            **self.rpc_values,
        }
        return SimpleNamespace(execute=lambda: SimpleNamespace(data=values.get(name)))

    def table(self, name):
        rows = self.tables.get(name, {
            "clinical_drafts": [{"id": "draft-1", "user_id": PATIENT, "state": "signed"}],
            "monthly_reports": [],
        }.get(name, []))
        return Query(rows)


class Query:
    def __init__(self, rows): self.rows, self.filters, self.maximum = rows, [], None
    def select(self, *_args, **_kwargs): return self
    def eq(self, key, value): self.filters.append((key, value)); return self
    def is_(self, key, value):
        assert value == "null"
        self.filters.append((key, None))
        return self
    def in_(self, key, values):
        self.filters.append((key, set(values)))
        return self
    def gt(self, key, value):
        self.filters.append((key, ("gt", value)))
        return self
    def limit(self, value): self.maximum = value; return self
    def execute(self):
        def matches(row, key, value):
            if isinstance(value, set): return row.get(key) in value
            if isinstance(value, tuple) and value[0] == "gt": return row.get(key) is not None and row.get(key) > value[1]
            return row.get(key) == value
        rows = [r for r in self.rows if all(matches(r, k, v) for k, v in self.filters)]
        return SimpleNamespace(data=rows[:self.maximum] if self.maximum is not None else rows)


def test_centre_assigns_doctor_to_patient_with_jwt_actor():
    db = Db()
    result = assign_patient(
        PATIENT,
        AssignmentCreate(doctor_id=DOCTOR, primary=True),
        owner_scope(),
        db,
    )
    assert result == {"id": "assignment-1"}
    assert db.calls[-1][1]["p_actor"] == OWNER


def test_assignment_uses_centre_derived_from_owner_scope():
    db = Db()

    assign_patient(PATIENT, AssignmentCreate(doctor_id=DOCTOR), owner_scope(), db)

    params = db.calls[-1][1]
    assert params["p_centre"] == CENTRE
    assert params["p_actor"] == OWNER


def test_centre_clinical_read_requires_consent_and_is_audited():
    denied = Db(consent=False)
    with pytest.raises(HTTPException) as error:
        read_centre_clinical_record(PATIENT, owner_scope(), denied)
    assert error.value.status_code == 403
    allowed = Db(consent=True)
    payload = read_centre_clinical_record(PATIENT, owner_scope(), allowed)
    assert payload["patient_id"] == PATIENT
    assert any(name == "record_access_event" for name, _ in allowed.calls)


def test_centre_clinical_read_fails_closed_when_audit_is_unavailable():
    with pytest.raises(HTTPException) as error:
        read_centre_clinical_record(
            PATIENT,
            owner_scope(),
            Db(consent=True, audit_fails=True),
        )

    assert error.value.status_code == 503


def test_operational_commands_always_use_resolved_scope():
    db = Db()
    db.rpc_values = {
        "create_centre_room": "room-1",
        "add_centre_room_hours": "hours-1",
        "create_centre_service": "service-1",
        "link_centre_room_service": "link-1",
        "end_centre_room_hours": "hours-1",
        "unlink_centre_room_service": "link-1",
        "create_centre_booking": "booking-1",
        "transition_centre_booking": "booking-1",
    }
    db.tables = {
        "centre_rooms": [{"id": "room-1", "centre_id": CENTRE}],
        "centre_room_hours": [{"id": "hours-1", "centre_id": CENTRE, "room_id": "room-1"}],
        "centre_services": [{"id": "service-1", "centre_id": CENTRE}],
        "centre_bookings": [{
            "id": "booking-1", "centre_id": CENTRE, "status": "booked", "version": 2,
        }],
    }

    create_room(RoomCreate(name="Room A"), owner_scope(), db)
    create_room_hours("room-1", RoomHoursCreate(weekday=1, opens_at="09:00", closes_at="17:00", valid_from="2026-10-01"), owner_scope(), db)
    create_service(ServiceCreate(name="Review", duration_minutes=30, indicative_price_minor=150000, currency_code="INR"), owner_scope(), db)
    link_room_service("service-1", "room-1", owner_scope(), db)
    assert end_room_hours("room-1", "hours-1", owner_scope(), db)["status"] == "ended"
    assert unlink_room_service("service-1", "room-1", owner_scope(), db)["status"] == "ended"
    created = create_booking(BookingCreate(patient_id=PATIENT, service_id="service-1", room_id="room-1", scheduled_start="2026-10-19T09:00:00Z"), owner_scope(), db)
    transitioned = transition_booking("booking-1", BookingTransition(command="check_in", expected_version=0), owner_scope(), db)

    assert created["id"] == "booking-1"
    assert created["status"] == "booked"
    assert transitioned["id"] == "booking-1"
    assert transitioned["version"] == 2

    operational_calls = [params for name, params in db.calls if name in db.rpc_values]
    assert operational_calls
    assert {params["p_centre"] for params in operational_calls} == {CENTRE}
    assert {params["p_actor"] for params in operational_calls} == {OWNER}


def test_booking_commands_return_authoritative_status_and_version():
    class BookingDb(Db):
        def __init__(self):
            super().__init__()
            self.tables = {
                "centre_bookings": [{
                    "id": "booking-1", "centre_id": CENTRE, "patient_id": PATIENT,
                    "service_id": "service-1", "room_id": "room-1",
                    "scheduled_start": "2026-10-19T09:00:00+00:00",
                    "scheduled_end": "2026-10-19T09:30:00+00:00",
                    "status": "booked", "version": 0,
                    "service_name_snapshot": "Review", "duration_minutes_snapshot": 30,
                    "indicative_price_minor_snapshot": 150000,
                    "currency_code_snapshot": "INR",
                }],
            }
            self.rpc_values = {
                "create_centre_booking": "booking-1",
                "transition_centre_booking": "booking-1",
            }

        def rpc(self, name, params):
            result = super().rpc(name, params)
            if name == "transition_centre_booking":
                self.tables["centre_bookings"][0].update(status="checked_in", version=1)
            return result

    db = BookingDb()
    created = create_booking(
        BookingCreate(patient_id=PATIENT, service_id="service-1", room_id="room-1", scheduled_start="2026-10-19T09:00:00Z"),
        owner_scope(), db,
    )
    transitioned = transition_booking(
        "booking-1", BookingTransition(command="check_in", expected_version=0), owner_scope(), db,
    )

    assert (created["status"], created["version"]) == ("booked", 0)
    assert (transitioned["status"], transitioned["version"]) == ("checked_in", 1)


def test_foreign_operational_ids_are_not_an_existence_oracle():
    db = Db()
    db.tables = {"centre_bookings": []}
    with pytest.raises(HTTPException) as error:
        transition_booking(
            "foreign-booking",
            BookingTransition(command="cancel", expected_version=0),
            owner_scope(),
            db,
        )
    assert error.value.status_code == 404


def test_stale_or_invalid_booking_transitions_are_conflicts():
    class ConflictDb(Db):
        def rpc(self, name, params):
            if name == "transition_centre_booking":
                error = RuntimeError("stale booking version")
                error.code = "40001"
                raise error
            return super().rpc(name, params)

    db = ConflictDb()
    db.tables = {"centre_bookings": [{"id": "booking-1", "centre_id": CENTRE}]}
    with pytest.raises(HTTPException) as error:
        transition_booking("booking-1", BookingTransition(command="check_in", expected_version=0), owner_scope(), db)
    assert error.value.status_code == 409


def test_lists_are_bounded_and_members_use_the_audited_loader():
    assert list_bookings(owner_scope(), Db(), limit=200, offset=0)["limit"] == 200
    with pytest.raises(ValueError):
        list_bookings(owner_scope(), Db(), limit=201, offset=0)

    db = Db(audit_fails=True)
    db.tables = {
        "clinical_access_consents": [{"centre_id": CENTRE, "patient_id": PATIENT, "purpose": "clinical_care", "revoked_at": None, "expires_at": "2999-01-01T00:00:00Z"}],
        "centre_memberships": [{"centre_id": CENTRE, "user_id": PATIENT, "member_kind": "patient", "status": "active", "left_at": None}],
    }
    with pytest.raises(HTTPException) as error:
        list_members(owner_scope(), db, limit=100, offset=0)
    assert error.value.status_code == 503


class ApiDb(FakeSupabase):
    def __init__(self, role="centre"):
        super().__init__({
            "profiles": [{"id": OWNER, "app_role": role, "full_name": "Owner"}],
            "centres": [{"id": CENTRE, "name": "Centre", "status": "active", "timezone_name": "Asia/Kolkata", "currency_code": "INR"}],
            "centre_memberships": [{"id": MEMBERSHIP, "centre_id": CENTRE, "user_id": OWNER, "member_kind": "owner", "status": "active", "left_at": None}],
            "centre_rooms": [], "centre_room_hours": [], "centre_services": [],
            "centre_room_services": [], "centre_bookings": [],
            "clinical_access_consents": [],
        })
        self.calls = []

    def rpc(self, name, params=None):
        self.calls.append((name, params or {}))
        return SimpleNamespace(execute=lambda: SimpleNamespace(data=True))


def api_client(db, *, authenticated=True):
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[get_supabase_client] = lambda: db
    if authenticated:
        app.dependency_overrides[current_user_id] = lambda: OWNER
    return TestClient(app)


def test_centre_api_requires_authentication_and_selected_membership():
    assert api_client(ApiDb(), authenticated=False).get("/api/v1/centre/rooms").status_code == 401
    assert api_client(ApiDb()).get("/api/v1/centre/rooms").status_code == 403
    response = api_client(ApiDb()).get("/api/v1/centre/rooms", headers={"X-Centre-Membership": MEMBERSHIP})
    assert response.status_code == 200


def test_centre_api_refuses_wrong_role_old_centre_paths_and_unbounded_pages():
    headers = {"X-Centre-Membership": MEMBERSHIP}
    client = api_client(ApiDb(role="member"))
    assert client.get("/api/v1/centre/rooms", headers=headers).status_code == 403
    client = api_client(ApiDb())
    assert client.get(f"/api/v1/centre/{CENTRE}/rooms", headers=headers).status_code == 404
    assert client.get("/api/v1/centre/bookings?limit=201", headers=headers).status_code == 422


def test_centre_router_exposes_every_f11_operational_surface():
    paths = {route.path for route in router.routes}
    assert {
        "/api/v1/centre/dashboard", "/api/v1/centre/members",
        "/api/v1/centre/doctors", "/api/v1/centre/patients", "/api/v1/centre/invitations",
        "/api/v1/centre/patients/{patient_id}/assignments",
        "/api/v1/centre/rooms", "/api/v1/centre/rooms/{room_id}/hours",
        "/api/v1/centre/services",
        "/api/v1/centre/services/{service_id}/compatible-rooms/{room_id}",
        "/api/v1/centre/bookings",
        "/api/v1/centre/bookings/{booking_id}/transitions",
        "/api/v1/centre/therapy-offerings",
        "/api/v1/centre/therapy-sessions",
    } <= paths

    methods = {
        method
        for route in router.routes
        if route.path == "/api/v1/centre/therapy-sessions"
        for method in route.methods
    }
    assert {"GET", "POST"} <= methods


def test_centre_can_create_an_operational_offering_but_not_clinical_content():
    db = FakeSupabase({
        "therapy_catalogue": [{"id": "cat-1", "publication_status": "published"}],
        "centre_therapy_offerings": [],
    })
    row = create_therapy_offering(
        TherapyOfferingCreate(catalogue_id="cat-1", indicative_price_minor=150000,
                              currency_code="INR"),
        owner_scope(), db,
    )
    assert row["centre_id"] == CENTRE
    assert row["created_by"] == OWNER
    assert row["price_qualifier"] == "Indicative"
    assert "prescribed_dose" not in row
