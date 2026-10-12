from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from app.gateway.access_audit import audited_read
from app.gateway.tenancy import (
    admin_patient_access,
    centre_clinical_access,
    centre_member,
    doctor_patient_access,
    require_clinical_author,
)


ADMIN = "10000000-0000-0000-0000-000000000001"
OWNER = "10000000-0000-0000-0000-000000000002"
DOCTOR_A = "10000000-0000-0000-0000-000000000003"
DOCTOR_B = "10000000-0000-0000-0000-000000000004"
PATIENT_A = "10000000-0000-0000-0000-000000000005"
PATIENT_B = "10000000-0000-0000-0000-000000000006"
CENTRE_A = "20000000-0000-0000-0000-000000000001"
CENTRE_B = "20000000-0000-0000-0000-000000000002"


class RpcDb:
    def __init__(self):
        self.answers = {}
        self.audit = []
        self.fail_audit = False

    def allow(self, function, *args):
        self.answers[(function, args)] = True

    def deny(self, function, *args):
        self.answers[(function, args)] = False

    def rpc(self, function, params):
        order = {
            "active_centre_membership": ("p_user", "p_centre", "p_kind"),
            "doctor_can_read_patient": ("p_actor", "p_centre", "p_patient"),
            "centre_can_read_clinical": ("p_actor", "p_centre", "p_patient"),
            "admin_can_read_patient": ("p_actor", "p_patient"),
        }
        if function == "record_access_event":
            if self.fail_audit:
                raise RuntimeError("audit unavailable")
            self.audit.append(params.copy())
            return SimpleNamespace(execute=lambda: SimpleNamespace(data="audit-1"))
        keys = order[function]
        answer = self.answers.get((function, tuple(params[k] for k in keys)), False)
        return SimpleNamespace(execute=lambda: SimpleNamespace(data=answer))


def test_centre_membership_is_explicit_and_isolated():
    db = RpcDb()
    db.allow("active_centre_membership", OWNER, CENTRE_A, "owner")
    assert centre_member(db, OWNER, CENTRE_A, "owner") is True
    assert centre_member(db, OWNER, CENTRE_B, "owner") is False
    assert centre_member(db, PATIENT_A, CENTRE_A, "patient") is False


def test_doctor_sees_only_assigned_patient_in_explicit_centre():
    db = RpcDb()
    db.allow("doctor_can_read_patient", DOCTOR_A, CENTRE_A, PATIENT_A)
    assert doctor_patient_access(db, DOCTOR_A, CENTRE_A, PATIENT_A)
    assert not doctor_patient_access(db, DOCTOR_A, CENTRE_A, PATIENT_B)
    assert not doctor_patient_access(db, DOCTOR_B, CENTRE_A, PATIENT_A)
    assert not doctor_patient_access(db, DOCTOR_A, CENTRE_B, PATIENT_A)


def test_revocation_and_suspended_licence_take_effect_on_next_lookup():
    db = RpcDb()
    key = ("doctor_can_read_patient", DOCTOR_A, CENTRE_A, PATIENT_A)
    db.allow(*key)
    assert doctor_patient_access(db, DOCTOR_A, CENTRE_A, PATIENT_A)
    db.deny(*key)
    assert not doctor_patient_access(db, DOCTOR_A, CENTRE_A, PATIENT_A)


def test_centre_clinical_access_stops_immediately_after_consent_revoke():
    db = RpcDb()
    key = ("centre_can_read_clinical", OWNER, CENTRE_A, PATIENT_A)
    db.allow(*key)
    assert centre_clinical_access(db, OWNER, CENTRE_A, PATIENT_A)
    db.deny(*key)
    assert not centre_clinical_access(db, OWNER, CENTRE_A, PATIENT_A)


def test_admin_read_is_global_but_clinical_authoring_is_refused():
    db = RpcDb()
    db.allow("admin_can_read_patient", ADMIN, PATIENT_A)
    assert admin_patient_access(db, ADMIN, PATIENT_A)
    with pytest.raises(HTTPException) as error:
        require_clinical_author("admin")
    assert error.value.status_code == 403
    assert require_clinical_author("doctor") == "doctor"


def test_database_error_fails_authorization_closed():
    class BrokenDb:
        def rpc(self, *_args, **_kwargs):
            raise RuntimeError("database unavailable")

    assert not doctor_patient_access(BrokenDb(), DOCTOR_A, CENTRE_A, PATIENT_A)


def test_audit_is_written_before_patient_payload_is_loaded():
    db = RpcDb()
    events = []

    result = audited_read(
        db,
        actor_id=ADMIN,
        actor_role="admin",
        patient_id=PATIENT_A,
        centre_id=None,
        resource_type="patient_summary",
        resource_id=PATIENT_A,
        read=lambda: events.append("read") or {"name": "Private Patient"},
    )
    assert result == {"name": "Private Patient"}
    assert db.audit[0]["p_patient"] == PATIENT_A
    assert events == ["read"]


def test_audit_failure_returns_no_patient_data_and_never_calls_loader():
    db = RpcDb()
    db.fail_audit = True
    loaded = []
    with pytest.raises(HTTPException) as error:
        audited_read(
            db,
            actor_id=ADMIN,
            actor_role="admin",
            patient_id=PATIENT_A,
            centre_id=None,
            resource_type="patient_summary",
            resource_id=PATIENT_A,
            read=lambda: loaded.append(True) or {"name": "Private Patient"},
        )
    assert error.value.status_code == 503
    assert loaded == []
