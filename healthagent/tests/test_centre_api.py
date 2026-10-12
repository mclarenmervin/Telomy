from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from app.gateway.api.centre import (
    AssignmentCreate,
    assign_patient,
    read_centre_clinical_record,
)


OWNER = "10000000-0000-0000-0000-000000000001"
DOCTOR = "10000000-0000-0000-0000-000000000002"
PATIENT = "10000000-0000-0000-0000-000000000003"
CENTRE = "20000000-0000-0000-0000-000000000001"


class Db:
    def __init__(self, consent=True):
        self.calls = []
        self.consent = consent

    def rpc(self, name, params):
        self.calls.append((name, params))
        values = {
            "active_centre_membership": True,
            "centre_can_read_clinical": self.consent,
            "assign_patient_doctor": "assignment-1",
            "record_access_event": "audit-1",
        }
        return SimpleNamespace(execute=lambda: SimpleNamespace(data=values.get(name)))

    def table(self, name):
        rows = {
            "clinical_drafts": [{"id": "draft-1", "user_id": PATIENT, "state": "signed"}],
            "monthly_reports": [],
        }.get(name, [])
        return Query(rows)


class Query:
    def __init__(self, rows): self.rows, self.filters = rows, []
    def select(self, *_args, **_kwargs): return self
    def eq(self, key, value): self.filters.append((key, value)); return self
    def execute(self): return SimpleNamespace(data=[r for r in self.rows if all(r.get(k) == v for k, v in self.filters)])


def test_centre_assigns_doctor_to_patient_with_jwt_actor():
    db = Db()
    result = assign_patient(CENTRE, PATIENT, AssignmentCreate(doctor_id=DOCTOR, primary=True), OWNER, db)
    assert result == {"id": "assignment-1"}
    assert db.calls[-1][1]["p_actor"] == OWNER


def test_cross_centre_owner_is_refused_before_assignment():
    db = Db()
    original = db.rpc
    db.rpc = lambda name, params: SimpleNamespace(execute=lambda: SimpleNamespace(data=False)) if name == "active_centre_membership" else original(name, params)
    with pytest.raises(HTTPException) as error:
        assign_patient(CENTRE, PATIENT, AssignmentCreate(doctor_id=DOCTOR), OWNER, db)
    assert error.value.status_code == 403


def test_centre_clinical_read_requires_consent_and_is_audited():
    denied = Db(consent=False)
    with pytest.raises(HTTPException) as error:
        read_centre_clinical_record(CENTRE, PATIENT, OWNER, denied)
    assert error.value.status_code == 403
    allowed = Db(consent=True)
    payload = read_centre_clinical_record(CENTRE, PATIENT, OWNER, allowed)
    assert payload["patient_id"] == PATIENT
    assert any(name == "record_access_event" for name, _ in allowed.calls)
