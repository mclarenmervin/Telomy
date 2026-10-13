from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.common.supabase_client import get_supabase_client
from app.gateway.auth import current_user_id
from app.gateway.invitations import (
    InvitationService,
    SupabaseAuthInvitationProvider,
    SupabaseInvitationStore,
)
from app.gateway.roles import app_role_of

router = APIRouter(prefix="/api/v1/invitations", tags=["accounts"])
care_router = APIRouter(prefix="/api/v1/account/care", tags=["accounts"])


class InvitationDecision(BaseModel):
    invitation_id: str


class ConsentDecision(BaseModel):
    granted: bool


def get_invitation_service(
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> InvitationService:
    return InvitationService(
        store=SupabaseInvitationStore(supabase),
        auth=SupabaseAuthInvitationProvider(supabase),
    )


def _email_for(supabase: Any, user_id: str) -> str:
    rows = (
        supabase.table("profiles")
        .select("email")
        .eq("id", user_id)
        .limit(1)
        .execute()
        .data
    )
    return str(rows[0].get("email") or "").strip().lower() if rows else ""


@router.get("/pending")
def pending_invitations(
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    service: Annotated[InvitationService, Depends(get_invitation_service)],
):
    return [service.result_dict(item) for item in service.pending(user_id, _email_for(supabase, user_id))]


@router.post("/accept")
def accept_invitation(
    body: InvitationDecision,
    user_id: Annotated[str, Depends(current_user_id)],
    service: Annotated[InvitationService, Depends(get_invitation_service)],
):
    return service.result_dict(service.accept(body.invitation_id, user_id))


@router.post("/{invitation_id}/accept")
def accept_invitation_by_id(invitation_id: str, user_id: Annotated[str, Depends(current_user_id)], service: Annotated[InvitationService, Depends(get_invitation_service)]):
    return service.result_dict(service.accept(invitation_id, user_id))


@router.post("/decline")
def decline_invitation(
    body: InvitationDecision,
    user_id: Annotated[str, Depends(current_user_id)],
    service: Annotated[InvitationService, Depends(get_invitation_service)],
):
    return service.result_dict(service.decline(body.invitation_id, user_id))


@router.post("/{invitation_id}/decline")
def decline_invitation_by_id(invitation_id: str, user_id: Annotated[str, Depends(current_user_id)], service: Annotated[InvitationService, Depends(get_invitation_service)]):
    return service.result_dict(service.decline(invitation_id, user_id))


def _require_patient(supabase: Any, user_id: str) -> None:
    if app_role_of(supabase, user_id) != "member":
        raise HTTPException(status_code=403, detail="not permitted")


def _active_patient_membership(supabase: Any, user_id: str, centre_id: str) -> bool:
    rows = (
        supabase.table("centre_memberships")
        .select("id")
        .eq("user_id", user_id)
        .eq("centre_id", centre_id)
        .eq("member_kind", "patient")
        .eq("status", "active")
        .is_("left_at", "null")
        .limit(1)
        .execute()
        .data
    )
    return bool(rows)


@care_router.get("")
def patient_care(
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    """Return only the signed-in Patient's current centres and care team."""
    _require_patient(supabase, user_id)
    memberships = (
        supabase.table("centre_memberships")
        .select("centre_id")
        .eq("user_id", user_id)
        .eq("member_kind", "patient")
        .eq("status", "active")
        .is_("left_at", "null")
        .execute()
        .data
        or []
    )
    centre_ids = [row["centre_id"] for row in memberships]
    centres = (
        supabase.table("centres")
        .select("id,name,status")
        .in_("id", centre_ids)
        .eq("status", "active")
        .execute()
        .data
        if centre_ids
        else []
    ) or []
    assignments = (
        supabase.table("patient_doctor_assignments")
        .select("id,centre_id,doctor_id,is_primary")
        .eq("patient_id", user_id)
        .in_("centre_id", centre_ids)
        .is_("ended_at", "null")
        .execute()
        .data
        if centre_ids
        else []
    ) or []
    doctor_ids = list(dict.fromkeys(row["doctor_id"] for row in assignments))
    doctors = (
        supabase.table("profiles")
        .select("id,full_name")
        .in_("id", doctor_ids)
        .execute()
        .data
        if doctor_ids
        else []
    ) or []
    doctor_names = {row["id"]: row.get("full_name") or "Doctor" for row in doctors}
    consents = (
        supabase.table("clinical_access_consents")
        .select("id,centre_id,purpose,granted_at,revoked_at,revoke_reason")
        .eq("patient_id", user_id)
        .in_("centre_id", centre_ids)
        .eq("purpose", "clinical_care")
        .order("granted_at", desc=True)
        .execute()
        .data
        if centre_ids
        else []
    ) or []

    items = []
    for centre in centres:
        centre_id = centre["id"]
        centre_assignments = [
            row for row in assignments if row["centre_id"] == centre_id
        ]
        centre_assignments.sort(key=lambda row: not bool(row.get("is_primary")))
        history = [row for row in consents if row["centre_id"] == centre_id]
        items.append({
            "id": centre_id,
            "name": centre.get("name") or "Centre",
            "doctors": [
                {
                    "id": row["doctor_id"],
                    "name": doctor_names.get(row["doctor_id"], "Doctor"),
                    "is_primary": bool(row.get("is_primary")),
                }
                for row in centre_assignments
            ],
            "consent": {
                "active": any(row.get("revoked_at") is None for row in history),
                "history": history,
            },
        })
    return {"centres": items}


@care_router.post("/{centre_id}/consent")
def set_patient_care_consent(
    centre_id: str,
    body: ConsentDecision,
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    _require_patient(supabase, user_id)
    if not _active_patient_membership(supabase, user_id, centre_id):
        raise HTTPException(status_code=403, detail="not permitted")
    try:
        consent_id = supabase.rpc(
            "set_clinical_access_consent",
            {
                "p_actor": user_id,
                "p_centre": centre_id,
                "p_patient": user_id,
                "p_granted": body.granted,
                "p_purpose": "clinical_care",
            },
        ).execute().data
    except Exception as error:
        raise HTTPException(status_code=409, detail="consent could not be changed") from error
    return {"id": str(consent_id), "active": body.granted}
