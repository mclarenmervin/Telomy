"""Current-state tenant and patient authorization.

Every check delegates to a PostgreSQL predicate on every request. Nothing is
cached from a JWT or a previous screen, so revocations take effect immediately.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated, Any, Callable

from fastapi import Depends, HTTPException

from app.common.logging_config import get_logger
from app.common.supabase_client import get_supabase_client
from app.gateway.auth import current_user_id
from app.gateway.roles import app_role_of

logger = get_logger(__name__)
CENTRE_KINDS = frozenset({"owner", "doctor", "patient"})


def _rpc_boolean(supabase: Any, function: str, params: dict[str, Any]) -> bool:
    try:
        value = supabase.rpc(function, params).execute().data
        if isinstance(value, list):
            value = value[0] if value else False
        return value is True
    except Exception:
        logger.exception("current-state authorization lookup failed")
        return False


def centre_member(supabase: Any, actor_id: str, centre_id: str, kind: str) -> bool:
    if kind not in CENTRE_KINDS or not centre_id:
        return False
    return _rpc_boolean(
        supabase,
        "active_centre_membership",
        {"p_user": actor_id, "p_centre": centre_id, "p_kind": kind},
    )


def doctor_patient_access(
    supabase: Any, actor_id: str, centre_id: str, patient_id: str
) -> bool:
    return _rpc_boolean(
        supabase,
        "doctor_can_read_patient",
        {"p_actor": actor_id, "p_centre": centre_id, "p_patient": patient_id},
    )


def centre_clinical_access(
    supabase: Any, actor_id: str, centre_id: str, patient_id: str
) -> bool:
    return _rpc_boolean(
        supabase,
        "centre_can_read_clinical",
        {"p_actor": actor_id, "p_centre": centre_id, "p_patient": patient_id},
    )


def admin_patient_access(supabase: Any, actor_id: str, patient_id: str) -> bool:
    return _rpc_boolean(
        supabase,
        "admin_can_read_patient",
        {"p_actor": actor_id, "p_patient": patient_id},
    )


def require_clinical_author(role: str) -> str:
    if role != "doctor":
        raise HTTPException(status_code=403, detail="not permitted")
    return role


@dataclass(frozen=True)
class AccessScope:
    actor_id: str
    actor_role: str
    centre_id: str
    patient_id: str | None = None


def _forbidden() -> HTTPException:
    return HTTPException(status_code=403, detail="not permitted")


def require_centre_member(kind: str) -> Callable[..., AccessScope]:
    if kind not in CENTRE_KINDS:
        raise ValueError(f"unknown centre membership kind: {kind}")

    def dependency(
        centre_id: str,
        actor_id: Annotated[str, Depends(current_user_id)],
        supabase: Annotated[Any, Depends(get_supabase_client)],
    ) -> AccessScope:
        if not centre_member(supabase, actor_id, centre_id, kind):
            raise _forbidden()
        return AccessScope(actor_id, app_role_of(supabase, actor_id), centre_id)

    return dependency


def require_doctor_patient_access() -> Callable[..., AccessScope]:
    def dependency(
        centre_id: str,
        patient_id: str,
        actor_id: Annotated[str, Depends(current_user_id)],
        supabase: Annotated[Any, Depends(get_supabase_client)],
    ) -> AccessScope:
        if not doctor_patient_access(supabase, actor_id, centre_id, patient_id):
            raise _forbidden()
        return AccessScope(actor_id, "doctor", centre_id, patient_id)

    return dependency


def require_centre_clinical_access() -> Callable[..., AccessScope]:
    def dependency(
        centre_id: str,
        patient_id: str,
        actor_id: Annotated[str, Depends(current_user_id)],
        supabase: Annotated[Any, Depends(get_supabase_client)],
    ) -> AccessScope:
        if not centre_clinical_access(supabase, actor_id, centre_id, patient_id):
            raise _forbidden()
        return AccessScope(actor_id, "centre", centre_id, patient_id)

    return dependency
