from __future__ import annotations

from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from app.common.context_loader import ContextLoader
from app.concierge.tools import build_concierge_tools
from app.gateway.centre_loader import CentreLoader
from app.gateway.tenancy import CentreOwnerScope
from tests.fakes import FakeSupabase


OWNER = "10000000-0000-0000-0000-000000000001"
CENTRE_A = "20000000-0000-0000-0000-000000000001"
CENTRE_B = "20000000-0000-0000-0000-000000000002"
PATIENT_A = "30000000-0000-0000-0000-000000000001"
PATIENT_NEVER = "30000000-0000-0000-0000-000000000002"
PATIENT_EXPIRED = "30000000-0000-0000-0000-000000000003"
PATIENT_B = "30000000-0000-0000-0000-000000000004"
DOCTOR_A = "40000000-0000-0000-0000-000000000001"
DOCTOR_B = "40000000-0000-0000-0000-000000000002"


def scope() -> CentreOwnerScope:
    return CentreOwnerScope(
        actor_id=OWNER,
        membership_id="50000000-0000-0000-0000-000000000001",
        centre_id=CENTRE_A,
    )


class AuditDb(FakeSupabase):
    def __init__(self, tables):
        super().__init__(tables)
        self.audit_calls: list[dict] = []
        self.fail_audit_at: int | None = None

    def rpc(self, function, params=None):
        if function != "record_access_event":
            return super().rpc(function, params)
        call_number = len(self.audit_calls) + 1
        if self.fail_audit_at == call_number:
            raise RuntimeError("audit unavailable")
        self.audit_calls.append(dict(params or {}))
        return SimpleNamespace(execute=lambda: SimpleNamespace(data=f"audit-{call_number}"))


def centre_db() -> AuditDb:
    now = datetime.now(UTC)
    future = (now + timedelta(days=30)).isoformat()
    expired = (now - timedelta(seconds=1)).isoformat()
    recent = (now - timedelta(days=2)).isoformat()
    return AuditDb({
        "centre_rooms": [
            {"id": "room-a", "centre_id": CENTRE_A, "name": "A"},
            {"id": "room-b", "centre_id": CENTRE_B, "name": "B"},
        ],
        "centre_room_hours": [
            {"id": "hours-a", "centre_id": CENTRE_A, "room_id": "room-a"},
            {"id": "hours-b", "centre_id": CENTRE_B, "room_id": "room-b"},
        ],
        "centre_services": [
            {"id": "service-a", "centre_id": CENTRE_A, "name": "A"},
            {"id": "service-b", "centre_id": CENTRE_B, "name": "B"},
        ],
        "centre_room_services": [
            {"id": "link-a", "centre_id": CENTRE_A, "room_id": "room-a"},
            {"id": "link-b", "centre_id": CENTRE_B, "room_id": "room-b"},
        ],
        "centre_bookings": [
            {
                "id": "booking-a",
                "centre_id": CENTRE_A,
                "patient_id": PATIENT_A,
                "status": "completed",
                "scheduled_start": recent,
                "completed_at": recent,
            },
            {
                "id": "booking-never",
                "centre_id": CENTRE_A,
                "patient_id": PATIENT_NEVER,
                "status": "completed",
                "scheduled_start": recent,
                "completed_at": recent,
            },
            {
                "id": "booking-b",
                "centre_id": CENTRE_B,
                "patient_id": PATIENT_B,
                "status": "booked",
                "scheduled_start": future,
            },
        ],
        "centre_booking_transitions": [
            {"id": "transition-a", "centre_id": CENTRE_A, "booking_id": "booking-a"},
            {"id": "transition-b", "centre_id": CENTRE_B, "booking_id": "booking-b"},
        ],
        "centre_memberships": [
            {"id": "doctor-membership-a", "centre_id": CENTRE_A, "user_id": DOCTOR_A, "member_kind": "doctor", "status": "active", "left_at": None},
            {"id": "doctor-membership-b", "centre_id": CENTRE_B, "user_id": DOCTOR_B, "member_kind": "doctor", "status": "active", "left_at": None},
            {"id": "patient-membership-a", "centre_id": CENTRE_A, "user_id": PATIENT_A, "member_kind": "patient", "status": "active", "left_at": None},
            {"id": "patient-membership-never", "centre_id": CENTRE_A, "user_id": PATIENT_NEVER, "member_kind": "patient", "status": "active", "left_at": None},
            {"id": "patient-membership-expired", "centre_id": CENTRE_A, "user_id": PATIENT_EXPIRED, "member_kind": "patient", "status": "active", "left_at": None},
            {"id": "patient-membership-b", "centre_id": CENTRE_B, "user_id": PATIENT_B, "member_kind": "patient", "status": "active", "left_at": None},
        ],
        "clinical_access_consents": [
            {"id": "consent-a", "centre_id": CENTRE_A, "patient_id": PATIENT_A, "purpose": "clinical_care", "expires_at": future, "revoked_at": None},
            {"id": "consent-expired", "centre_id": CENTRE_A, "patient_id": PATIENT_EXPIRED, "purpose": "clinical_care", "expires_at": expired, "revoked_at": None},
            {"id": "consent-b", "centre_id": CENTRE_B, "patient_id": PATIENT_B, "purpose": "clinical_care", "expires_at": future, "revoked_at": None},
        ],
        "profiles": [
            {"id": PATIENT_A, "full_name": "Patient A", "email": "a@example.com", "phone": "secret", "address": "secret"},
            {"id": PATIENT_NEVER, "full_name": "Never Consented", "email": "never@example.com"},
            {"id": PATIENT_EXPIRED, "full_name": "Expired", "email": "expired@example.com"},
            {"id": PATIENT_B, "full_name": "Patient B", "email": "b@example.com"},
            {"id": DOCTOR_A, "full_name": "Doctor A", "email": "doctor-a@example.com"},
            {"id": DOCTOR_B, "full_name": "Doctor B", "email": "doctor-b@example.com"},
        ],
        "patient_doctor_assignments": [
            {"id": "assignment-a", "centre_id": CENTRE_A, "patient_id": PATIENT_A, "doctor_id": DOCTOR_A, "is_primary": True, "ended_at": None},
            {"id": "assignment-b", "centre_id": CENTRE_B, "patient_id": PATIENT_B, "doctor_id": DOCTOR_B, "is_primary": True, "ended_at": None},
        ],
        "lab_escalations": [
            {"id": "risk-a", "user_id": PATIENT_A, "severity": "critical", "created_at": recent, "value_canonical": 999.0, "message": "secret clinical text"},
            {"id": "risk-never", "user_id": PATIENT_NEVER, "severity": "critical", "created_at": recent, "value_canonical": 888.0},
            {"id": "risk-expired", "user_id": PATIENT_EXPIRED, "severity": "critical", "created_at": recent, "value_canonical": 777.0},
            {"id": "risk-b", "user_id": PATIENT_B, "severity": "critical", "created_at": recent, "value_canonical": 666.0},
        ],
    })


def test_every_operational_loader_method_is_centre_scoped():
    loader = CentreLoader(centre_db(), scope())

    for rows in (
        loader.rooms(),
        loader.room_hours(),
        loader.services(),
        loader.room_services(),
        loader.bookings(),
        loader.booking_transitions(),
    ):
        assert rows
        assert {row["centre_id"] for row in rows} == {CENTRE_A}
    doctors = loader.doctors()
    assert {row["id"] for row in doctors} == {DOCTOR_A}
    assert {row["centre_id"] for row in doctors} == {CENTRE_A}


def test_member_snapshot_excludes_unconsented_expired_foreign_and_contact_data():
    db = centre_db()
    snapshot = CentreLoader(db, scope(), request_id="request-1").member_snapshot()

    assert snapshot["member_count"] == 1
    assert [item["id"] for item in snapshot["items"]] == [PATIENT_A]
    assert [item["id"] for item in snapshot["risk_candidates"]] == [PATIENT_A]
    assert snapshot["not_seen_candidates"] == []
    serialized = repr(snapshot).lower()
    for forbidden in ("email", "phone", "address", "value_canonical", "999", "secret"):
        assert forbidden not in serialized
    assert [call["p_patient"] for call in db.audit_calls] == [PATIENT_A]


def test_revocation_and_expiry_disappear_without_rebuilding_loader():
    db = centre_db()
    loader = CentreLoader(db, scope())
    assert loader.member_snapshot()["member_count"] == 1

    db.tables["clinical_access_consents"][0]["revoked_at"] = datetime.now(UTC).isoformat()
    assert loader.member_snapshot()["items"] == []
    db.tables["clinical_access_consents"][0]["revoked_at"] = None
    db.tables["clinical_access_consents"][0]["expires_at"] = (
        datetime.now(UTC) - timedelta(seconds=1)
    ).isoformat()
    assert loader.member_snapshot()["items"] == []


def test_any_member_audit_failure_prevents_the_payload():
    db = centre_db()
    db.tables["clinical_access_consents"].append({
        "id": "consent-never",
        "centre_id": CENTRE_A,
        "patient_id": PATIENT_NEVER,
        "purpose": "clinical_care",
        "expires_at": (datetime.now(UTC) + timedelta(days=30)).isoformat(),
        "revoked_at": None,
    })
    db.fail_audit_at = 2

    with pytest.raises(HTTPException) as error:
        CentreLoader(db, scope()).member_snapshot()

    assert error.value.status_code == 503
    assert len(db.audit_calls) == 1


def test_gateway_loader_does_not_expand_agent_context_or_tools():
    assert not hasattr(ContextLoader, "centre_members")
    assert not hasattr(ContextLoader, "member_snapshot")
    names = {tool.name for tool in build_concierge_tools(ContextLoader(FakeSupabase({})))}
    assert not any("centre" in name or "patient" in name for name in names)
