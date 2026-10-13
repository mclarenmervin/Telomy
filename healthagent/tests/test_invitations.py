from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.common.supabase_client import get_supabase_client
from app.gateway.api.accounts import care_router, router as accounts_router
from app.gateway.auth import current_user_id
from app.gateway.invitations import InvitationService
from tests.fakes import FakeSupabase


ACTOR = "10000000-0000-0000-0000-000000000001"
CENTRE = "20000000-0000-0000-0000-000000000001"
DOCTOR = "30000000-0000-0000-0000-000000000001"
USER = "40000000-0000-0000-0000-000000000001"


class MemoryStore:
    def __init__(self):
        self.rows = []
        self.allowed = True
        self.fail_provider_write_once = False

    def create_intent(self, **values):
        if not self.allowed:
            raise PermissionError("not permitted")
        existing = next(
            (row for row in self.rows if row["inviter_id"] == values["inviter_id"]
             and row["idempotency_key"] == values["idempotency_key"]),
            None,
        )
        if existing:
            return existing.copy()
        row = {
            "id": f"invite-{len(self.rows) + 1}",
            "status": "pending",
            "created_at": datetime.now(UTC).isoformat(),
            "expires_at": (datetime.now(UTC) + timedelta(hours=24)).isoformat(),
            "provider_user_id": None,
            **values,
        }
        self.rows.append(row)
        return row.copy()

    def get(self, invitation_id):
        row = next((r for r in self.rows if r["id"] == invitation_id), None)
        return row.copy() if row else None

    def link_provider(self, invitation_id, provider_user_id):
        if self.fail_provider_write_once:
            self.fail_provider_write_once = False
            raise TimeoutError("database timeout")
        row = next(r for r in self.rows if r["id"] == invitation_id)
        row["provider_user_id"] = provider_user_id
        return row.copy()

    def pending_for(self, user_id, email):
        return [
            r.copy() for r in self.rows
            if r.get("status") == "pending"
            and (r.get("provider_user_id") == user_id or r["email"] == email.lower())
        ]

    def decide(self, invitation_id, user_id, decision):
        row = next(r for r in self.rows if r["id"] == invitation_id)
        if row["status"] != "pending":
            raise ValueError("invitation is not pending")
        if datetime.fromisoformat(row["expires_at"]) <= datetime.now(UTC):
            row["status"] = "expired"
            raise ValueError("invitation has expired")
        row["status"] = decision
        row["accepted_user_id"] = user_id if decision == "accepted" else None
        return row.copy()


class FakeAuth:
    def __init__(self, existing=None):
        self.users = dict(existing or {})
        self.invite_calls = 0

    def find_user_by_email(self, email):
        return self.users.get(email)

    def invite_user_by_email(self, email):
        self.invite_calls += 1
        user = SimpleNamespace(id=f"auth-{len(self.users) + 1}", email=email)
        self.users[email] = user
        return user


@pytest.fixture
def store():
    return MemoryStore()


@pytest.fixture
def auth():
    return FakeAuth()


@pytest.fixture
def service(store, auth):
    return InvitationService(store=store, auth=auth)


def invite(service, **overrides):
    values = dict(
        actor_id=ACTOR,
        email=" Patient@Example.COM ",
        intended_role="member",
        centre_id=CENTRE,
        primary_doctor_id=DOCTOR,
        idempotency_key="request-1",
    )
    values.update(overrides)
    return service.invite(**values)


def test_new_identity_is_invited_after_intent_is_persisted(service, store, auth):
    result = invite(service)
    assert result.invitation_id == "invite-1"
    assert result.email == "patient@example.com"
    assert result.status == "pending"
    assert store.rows[0]["provider_user_id"].startswith("auth-")
    assert auth.invite_calls == 1


def test_existing_identity_is_linked_without_duplicate_email(store):
    existing = SimpleNamespace(id=USER, email="patient@example.com")
    auth = FakeAuth({"patient@example.com": existing})
    result = invite(InvitationService(store=store, auth=auth))
    assert result.provider_user_id == USER
    assert auth.invite_calls == 0


def test_forbidden_inviter_fails_before_auth_delivery(service, store, auth):
    store.allowed = False
    with pytest.raises(HTTPException) as error:
        invite(service)
    assert error.value.status_code == 403
    assert auth.invite_calls == 0


def test_normalized_email_and_idempotency_dedupe(service, auth):
    first = invite(service)
    second = invite(service, email="patient@example.com")
    assert second.invitation_id == first.invitation_id
    assert auth.invite_calls == 1


def test_retry_after_auth_success_reconciles_without_duplicate_email(service, store, auth):
    store.fail_provider_write_once = True
    with pytest.raises(HTTPException) as error:
        invite(service)
    assert error.value.status_code == 503
    second = invite(service)
    assert second.provider_user_id == "auth-1"
    assert auth.invite_calls == 1


@pytest.mark.parametrize("status", ["expired", "revoked"])
def test_expired_or_revoked_invitation_cannot_be_accepted(service, store, status):
    result = invite(service)
    store.rows[0]["status"] = status
    with pytest.raises(HTTPException) as error:
        service.accept(result.invitation_id, "auth-1")
    assert error.value.status_code == 409


def test_doctor_invitation_remains_pending_verification(service, store):
    result = invite(service, intended_role="doctor", primary_doctor_id=None)
    assert result.requires_verification is True
    assert store.rows[0]["status"] == "pending"


def test_safe_result_never_contains_password_token_or_magic_link(service):
    payload = service.result_dict(invite(service))
    serialized = repr(payload).lower()
    assert "password" not in serialized
    assert "token" not in serialized
    assert "magic" not in serialized


def test_pending_accept_and_decline_are_recipient_scoped(service, store):
    accepted = invite(service)
    declined = invite(service, email="second@example.com", idempotency_key="request-2")
    assert [r.invitation_id for r in service.pending("auth-1", "patient@example.com")] == [
        accepted.invitation_id
    ]
    assert service.accept(accepted.invitation_id, "auth-1").status == "accepted"
    assert service.decline(declined.invitation_id, "auth-2").status == "declined"


def test_recipient_cannot_decide_another_accounts_invitation(service):
    result = invite(service)
    with pytest.raises(HTTPException) as error:
        service.accept(result.invitation_id, USER)
    assert error.value.status_code == 403


class PatientCareSupabase(FakeSupabase):
    def rpc(self, function, params=None):
        params = params or {}
        if function != "set_clinical_access_consent":
            return super().rpc(function, params)
        active = next(
            (
                row
                for row in self.tables["clinical_access_consents"]
                if row["patient_id"] == params["p_patient"]
                and row["centre_id"] == params["p_centre"]
                and row.get("revoked_at") is None
            ),
            None,
        )
        if params["p_granted"]:
            if active is None:
                active = {
                    "id": f"consent-{len(self.tables['clinical_access_consents']) + 1}",
                    "patient_id": params["p_patient"],
                    "centre_id": params["p_centre"],
                    "purpose": "clinical_care",
                    "granted_at": datetime.now(UTC).isoformat(),
                    "revoked_at": None,
                }
                self.tables["clinical_access_consents"].append(active)
        else:
            active["revoked_at"] = datetime.now(UTC).isoformat()
        return SimpleNamespace(execute=lambda: SimpleNamespace(data=active["id"]))


def patient_care_db(role="member"):
    return PatientCareSupabase({
        "profiles": [
            {"id": USER, "app_role": role, "full_name": "Alex"},
            {"id": DOCTOR, "app_role": "doctor", "full_name": "Dr Primary"},
            {"id": ACTOR, "app_role": "doctor", "full_name": "Dr Additional"},
        ],
        "centres": [{"id": CENTRE, "name": "Telomy Bengaluru", "status": "active"}],
        "centre_memberships": [{
            "id": "membership-1", "user_id": USER, "centre_id": CENTRE,
            "member_kind": "patient", "status": "active", "left_at": None,
        }],
        "patient_doctor_assignments": [
            {"id": "assignment-1", "patient_id": USER, "centre_id": CENTRE,
             "doctor_id": DOCTOR, "is_primary": True, "ended_at": None},
            {"id": "assignment-2", "patient_id": USER, "centre_id": CENTRE,
             "doctor_id": ACTOR, "is_primary": False, "ended_at": None},
        ],
        "clinical_access_consents": [],
    })


def patient_care_client(db, actor=USER):
    app = FastAPI()
    app.include_router(accounts_router)
    app.include_router(care_router)
    app.dependency_overrides[current_user_id] = lambda: actor
    app.dependency_overrides[get_supabase_client] = lambda: db
    return TestClient(app)


def test_patient_care_is_self_scoped_and_shows_primary_and_additional_doctors():
    response = patient_care_client(patient_care_db()).get("/api/v1/account/care")
    assert response.status_code == 200
    centre = response.json()["centres"][0]
    assert centre["name"] == "Telomy Bengaluru"
    assert [doctor["name"] for doctor in centre["doctors"]] == [
        "Dr Primary", "Dr Additional"
    ]
    assert centre["doctors"][0]["is_primary"] is True
    assert centre["consent"]["active"] is False


def test_patient_care_rejects_a_non_patient_even_with_a_valid_session():
    response = patient_care_client(patient_care_db(role="doctor")).get(
        "/api/v1/account/care"
    )
    assert response.status_code == 403


def test_patient_care_consent_grant_and_revoke_preserve_history():
    db = patient_care_db()
    client = patient_care_client(db)
    granted = client.post(f"/api/v1/account/care/{CENTRE}/consent", json={"granted": True})
    assert granted.status_code == 200
    assert client.get("/api/v1/account/care").json()["centres"][0]["consent"]["active"] is True
    revoked = client.post(f"/api/v1/account/care/{CENTRE}/consent", json={"granted": False})
    assert revoked.status_code == 200
    care = client.get("/api/v1/account/care").json()["centres"][0]
    assert care["consent"]["active"] is False
    assert len(care["consent"]["history"]) == 1


def test_patient_care_exposes_no_assignment_mutation_route():
    response = patient_care_client(patient_care_db()).post(
        f"/api/v1/account/care/{CENTRE}/assignments", json={"doctor_id": DOCTOR}
    )
    assert response.status_code == 404
