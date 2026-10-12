"""Safe, idempotent orchestration for Supabase Auth invitations.

The database owns invitation authority and membership creation. Supabase Auth
owns identities and email delivery. This module deliberately exposes neither
provider tokens nor magic links.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any, Protocol

from fastapi import HTTPException


@dataclass(frozen=True)
class InvitationResult:
    invitation_id: str
    email: str
    intended_role: str
    centre_id: str | None
    status: str
    provider_user_id: str | None = None
    requires_verification: bool = False
    expires_at: str | None = None


class InvitationStore(Protocol):
    def create_intent(self, **values: Any) -> dict[str, Any]: ...
    def get(self, invitation_id: str) -> dict[str, Any] | None: ...
    def link_provider(self, invitation_id: str, provider_user_id: str) -> dict[str, Any]: ...
    def pending_for(self, user_id: str, email: str) -> list[dict[str, Any]]: ...
    def decide(self, invitation_id: str, user_id: str, decision: str) -> dict[str, Any]: ...


class AuthInvitationProvider(Protocol):
    def find_user_by_email(self, email: str) -> Any | None: ...
    def invite_user_by_email(self, email: str) -> Any: ...


def _safe_error(status_code: int, detail: str) -> HTTPException:
    return HTTPException(status_code=status_code, detail=detail)


class InvitationService:
    """Coordinates a persisted intent with at-most-once provider delivery."""

    def __init__(self, store: InvitationStore, auth: AuthInvitationProvider):
        self.store = store
        self.auth = auth

    @staticmethod
    def _result(row: dict[str, Any]) -> InvitationResult:
        status = str(row.get("status") or "pending")
        return InvitationResult(
            invitation_id=str(row["id"]),
            email=str(row["email"]),
            intended_role=str(row["intended_role"]),
            centre_id=str(row["centre_id"]) if row.get("centre_id") else None,
            status=status,
            provider_user_id=(
                str(row["provider_user_id"]) if row.get("provider_user_id") else None
            ),
            requires_verification=row.get("intended_role") == "doctor",
            expires_at=str(row["expires_at"]) if row.get("expires_at") else None,
        )

    @staticmethod
    def result_dict(result: InvitationResult) -> dict[str, Any]:
        # An allow-listed dataclass is used rather than forwarding provider or
        # PostgREST payloads, which may acquire sensitive fields over time.
        return asdict(result)

    def invite(
        self,
        actor_id: str,
        email: str,
        intended_role: str,
        centre_id: str | None,
        primary_doctor_id: str | None,
        idempotency_key: str,
    ) -> InvitationResult:
        normalized_email = email.strip().lower()
        if "@" not in normalized_email or not idempotency_key.strip():
            raise _safe_error(422, "valid email and idempotency key are required")
        try:
            row = self.store.create_intent(
                inviter_id=actor_id,
                email=normalized_email,
                intended_role=intended_role,
                centre_id=centre_id,
                primary_doctor_id=primary_doctor_id,
                idempotency_key=idempotency_key.strip(),
            )
        except PermissionError:
            raise _safe_error(403, "not permitted") from None
        except ValueError:
            raise _safe_error(422, "invalid invitation") from None

        # A completed prior attempt is the authoritative idempotent result.
        if row.get("provider_user_id"):
            return self._result(row)

        try:
            user = self.auth.find_user_by_email(normalized_email)
            if user is None:
                user = self.auth.invite_user_by_email(normalized_email)
            provider_user_id = str(getattr(user, "id", None) or user["id"])
            row = self.store.link_provider(str(row["id"]), provider_user_id)
        except HTTPException:
            raise
        except Exception:
            # The intent remains pending. A retry finds the provider identity
            # before attempting a second delivery and completes reconciliation.
            raise _safe_error(503, "invitation delivery is being reconciled") from None
        return self._result(row)

    def reconcile(self, invitation_id: str) -> InvitationResult:
        row = self.store.get(invitation_id)
        if not row:
            raise _safe_error(404, "invitation not found")
        if row.get("provider_user_id"):
            return self._result(row)
        user = self.auth.find_user_by_email(str(row["email"]))
        if user is None:
            raise _safe_error(409, "invitation delivery is pending")
        provider_user_id = str(getattr(user, "id", None) or user["id"])
        return self._result(self.store.link_provider(invitation_id, provider_user_id))

    def pending(self, user_id: str, email: str) -> list[InvitationResult]:
        return [self._result(row) for row in self.store.pending_for(user_id, email.strip().lower())]

    def _decide(self, invitation_id: str, user_id: str, decision: str) -> InvitationResult:
        row = self.store.get(invitation_id)
        if not row:
            raise _safe_error(409, "invitation is not available")
        recipient_ids = {
            str(value)
            for value in (row.get("invited_user_id"), row.get("provider_user_id"))
            if value
        }
        if user_id not in recipient_ids:
            raise _safe_error(403, "not permitted")
        try:
            return self._result(self.store.decide(invitation_id, user_id, decision))
        except PermissionError:
            raise _safe_error(403, "not permitted") from None
        except (KeyError, ValueError):
            raise _safe_error(409, "invitation is not available") from None

    def accept(self, invitation_id: str, user_id: str) -> InvitationResult:
        return self._decide(invitation_id, user_id, "accepted")

    def decline(self, invitation_id: str, user_id: str) -> InvitationResult:
        return self._decide(invitation_id, user_id, "declined")


class SupabaseInvitationStore:
    """PostgREST/RPC adapter; actor authority remains enforced in PostgreSQL."""

    SAFE_COLUMNS = (
        "id,email,intended_role,centre_id,invited_by,invited_user_id,"
        "primary_doctor_id,status,idempotency_key,provider_user_id,expires_at,created_at"
    )

    def __init__(self, supabase: Any):
        self.db = supabase

    def get(self, invitation_id: str) -> dict[str, Any] | None:
        rows = (
            self.db.table("account_invitations")
            .select(self.SAFE_COLUMNS)
            .eq("id", invitation_id)
            .limit(1)
            .execute()
            .data
        )
        return rows[0] if rows else None

    def create_intent(self, **values: Any) -> dict[str, Any]:
        params = {
            "p_email": values["email"],
            "p_intended_role": values["intended_role"],
            "p_centre": values.get("centre_id"),
            "p_actor": values["inviter_id"],
            "p_primary_doctor": values.get("primary_doctor_id"),
            "p_idempotency_key": values["idempotency_key"],
        }
        try:
            response = self.db.rpc("create_account_invitation", params).execute()
        except Exception as error:
            if "42501" in str(error):
                raise PermissionError from error
            raise
        invitation_id = response.data
        if isinstance(invitation_id, list):
            invitation_id = invitation_id[0]
        row = self.get(str(invitation_id))
        if not row:
            raise RuntimeError("invitation intent was not persisted")
        return row

    def link_provider(self, invitation_id: str, provider_user_id: str) -> dict[str, Any]:
        rows = (
            self.db.table("account_invitations")
            .update({"provider_user_id": provider_user_id, "sent_at": "now()"})
            .eq("id", invitation_id)
            .eq("status", "pending")
            .execute()
            .data
        )
        if not rows:
            raise RuntimeError("invitation is no longer pending")
        return self.get(invitation_id) or rows[0]

    def pending_for(self, user_id: str, email: str) -> list[dict[str, Any]]:
        by_user = (
            self.db.table("account_invitations")
            .select(self.SAFE_COLUMNS)
            .eq("invited_user_id", user_id)
            .eq("status", "pending")
            .execute()
            .data
        )
        by_email = (
            self.db.table("account_invitations")
            .select(self.SAFE_COLUMNS)
            .eq("email", email)
            .eq("status", "pending")
            .execute()
            .data
        )
        return list({str(row["id"]): row for row in [*by_user, *by_email]}.values())

    def decide(self, invitation_id: str, user_id: str, decision: str) -> dict[str, Any]:
        if decision == "accepted":
            try:
                self.db.rpc(
                    "accept_account_invitation",
                    {"p_invitation": invitation_id, "p_user": user_id},
                ).execute()
            except Exception as error:
                if "42501" in str(error):
                    raise PermissionError from error
                raise ValueError from error
        else:
            rows = (
                self.db.table("account_invitations")
                .update({"status": "revoked", "revoked_at": "now()"})
                .eq("id", invitation_id)
                .eq("status", "pending")
                .execute()
                .data
            )
            if not rows:
                raise ValueError("invitation is not pending")
        row = self.get(invitation_id)
        if not row:
            raise ValueError("invitation is not available")
        if decision == "declined":
            row = {**row, "status": "declined"}
        return row


class SupabaseAuthInvitationProvider:
    def __init__(self, supabase: Any):
        self.admin = supabase.auth.admin

    def find_user_by_email(self, email: str) -> Any | None:
        # supabase-py has no stable direct email lookup across supported
        # versions. A bounded admin page is safe server-side; the database also
        # pre-links identities in create_account_invitation.
        response = self.admin.list_users(page=1, per_page=1000)
        users = getattr(response, "users", response) or []
        return next((user for user in users if str(user.email).lower() == email), None)

    def invite_user_by_email(self, email: str) -> Any:
        response = self.admin.invite_user_by_email(email)
        return getattr(response, "user", response)
