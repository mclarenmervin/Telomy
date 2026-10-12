from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from app.gateway.api.admin_people import (
    CentreCreate,
    VerificationDecision,
    create_centre,
    decide_verification,
    read_admin_clinical_record,
)


ADMIN = "10000000-0000-0000-0000-000000000001"
PATIENT = "10000000-0000-0000-0000-000000000002"


class Db:
    def __init__(self):
        self.calls = []
        self.audit = []
        self.tables = {
            "profiles": [{"id": PATIENT, "full_name": "Patient One", "app_role": "member"}],
            "clinical_drafts": [{"id": "draft-1", "user_id": PATIENT, "state": "signed"}],
            "monthly_reports": [{"id": "report-1", "patient_id": PATIENT, "status": "signed"}],
        }

    def rpc(self, name, params):
        self.calls.append((name, params))
        if name == "record_access_event":
            self.audit.append(params)
            value = "audit-1"
        elif name == "create_centre":
            value = "centre-1"
        elif name == "record_clinician_verification":
            value = "verification-1"
        elif name == "admin_can_read_patient":
            value = True
        else:
            value = None
        return SimpleNamespace(execute=lambda: SimpleNamespace(data=value))

    def table(self, name):
        return Query(self.tables.setdefault(name, []))


class Query:
    def __init__(self, rows):
        self.rows = rows
        self.filters = []

    def select(self, *_args, **_kwargs): return self
    def eq(self, key, value): self.filters.append((key, value)); return self
    def limit(self, _value): return self
    def range(self, _start, _end): return self
    def order(self, *_args, **_kwargs): return self
    def update(self, values):
        for row in self.rows:
            if all(row.get(k) == v for k, v in self.filters): row.update(values)
        return self
    def execute(self):
        rows = [r.copy() for r in self.rows if all(r.get(k) == v for k, v in self.filters)]
        return SimpleNamespace(data=rows)


def test_admin_creates_centre_via_rpc():
    db = Db()
    result = create_centre(CentreCreate(name="North Centre", owner_id=PATIENT), ADMIN, "admin", db)
    assert result == {"id": "centre-1", "name": "North Centre"}
    assert db.calls[0] == ("create_centre", {"p_name": "North Centre", "p_actor": ADMIN})


def test_only_admin_verification_rpc_receives_actor_from_jwt():
    db = Db()
    body = VerificationDecision(status="verified", reason="licence checked", registration_number="R1", registration_body="NMC", licence_expires_at="2030-01-01T00:00:00Z")
    result = decide_verification(PATIENT, body, ADMIN, "admin", db)
    assert result["id"] == "verification-1"
    assert db.calls[0][1]["p_actor"] == ADMIN


def test_admin_clinical_read_is_audited_and_read_only():
    db = Db()
    payload = read_admin_clinical_record(PATIENT, ADMIN, "admin", db)
    assert payload["patient_id"] == PATIENT
    assert db.audit and db.audit[0]["p_actor"] == ADMIN
    assert "mutations" not in payload


def test_admin_clinical_route_has_no_write_variant():
    from app.gateway.api.admin_people import router
    routes = {(route.path, method) for route in router.routes for method in route.methods}
    path = "/api/v1/admin/patients/{patient_id}/clinical-record"
    assert (path, "GET") in routes
    assert not any(item[0] == path and item[1] != "GET" for item in routes)
