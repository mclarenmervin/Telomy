"""Centre Owner operational roster and assignment APIs."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from pydantic import BaseModel, Field

from app.common.supabase_client import get_supabase_client
from app.gateway.access_audit import audited_read
from app.gateway.api.accounts import get_invitation_service
from app.gateway.auth import current_user_id
from app.gateway.invitations import InvitationService
from app.gateway.roles import CENTRE, require_app_role
from app.gateway.tenancy import (
    CentreOwnerScope,
    centre_clinical_access,
    require_centre_owner_scope,
)

router = APIRouter(prefix="/api/v1/centre", tags=["centre"])


class CentreInvitationCreate(BaseModel):
    email: str = Field(min_length=3, max_length=320)
    intended_role: Literal["doctor", "member"]
    primary_doctor_id: str | None = None


class AssignmentCreate(BaseModel):
    doctor_id: str
    primary: bool = False


class PrimaryDoctor(BaseModel):
    doctor_id: str


def _roster(supabase: Any, centre_id: str, kind: str, limit: int = 100) -> list[dict]:
    memberships = (
        supabase.table("centre_memberships")
        .select("id,user_id,status,accepted_at,joined_at")
        .eq("centre_id", centre_id).eq("member_kind", kind).is_("left_at", "null")
        .limit(limit).execute().data or []
    )
    ids = [row["user_id"] for row in memberships]
    if not ids:
        return []
    profiles = supabase.table("profiles").select("id,full_name,email,app_role").in_("id", ids).execute().data or []
    by_id = {row["id"]: row for row in profiles}
    return [{**row, "profile": by_id.get(row["user_id"], {})} for row in memberships]


@router.get("/mine")
def my_centres(
    actor_id: Annotated[str, Depends(current_user_id)],
    _: Annotated[str, Depends(require_app_role(CENTRE))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    memberships = (
        supabase.table("centre_memberships").select("id,centre_id")
        .eq("user_id", actor_id).eq("member_kind", "owner")
        .eq("status", "active").is_("left_at", "null").execute().data or []
    )
    ids = [row["centre_id"] for row in memberships]
    rows = (
        supabase.table("centres").select("id,name,status")
        .in_("id", ids).eq("status", "active").execute().data
        if ids else []
    )
    membership_by_centre = {row["centre_id"]: row["id"] for row in memberships}
    return {
        "items": [
            {**row, "membership_id": membership_by_centre[row["id"]]}
            for row in (rows or [])
        ]
    }


@router.get("/dashboard")
def centre_dashboard(
    scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    doctors = _roster(supabase, scope.centre_id, "doctor")
    patients = _roster(supabase, scope.centre_id, "patient")
    return {"centre_id": scope.centre_id, "doctors": len(doctors), "patients": len(patients)}


@router.get("/doctors")
def list_centre_doctors(scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], limit: int = Query(default=100, ge=1, le=200)) -> dict:
    return {"items": _roster(supabase, scope.centre_id, "doctor", limit)}


@router.get("/patients")
def list_centre_patients(scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], limit: int = Query(default=100, ge=1, le=200)) -> dict:
    return {"items": _roster(supabase, scope.centre_id, "patient", limit)}


@router.post("/invitations", status_code=201)
def create_centre_invitation(
    body: CentreInvitationCreate,
    scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    service: Annotated[InvitationService, Depends(get_invitation_service)],
    idempotency_key: Annotated[str, Header(alias="Idempotency-Key")],
) -> dict:
    result = service.invite(scope.actor_id, body.email, body.intended_role, scope.centre_id, body.primary_doctor_id, idempotency_key)
    return service.result_dict(result)


@router.post("/patients/{patient_id}/assignments", status_code=201)
def assign_patient(
    patient_id: str, body: AssignmentCreate,
    scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    assignment_id = supabase.rpc("assign_patient_doctor", {
        "p_actor": scope.actor_id, "p_centre": scope.centre_id, "p_patient": patient_id,
        "p_doctor": body.doctor_id, "p_primary": body.primary,
    }).execute().data
    return {"id": str(assignment_id)}


@router.patch("/patients/{patient_id}/primary-doctor")
def set_primary_doctor(patient_id: str, body: PrimaryDoctor, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    assignment_id = supabase.rpc("set_primary_doctor", {"p_actor": scope.actor_id, "p_centre": scope.centre_id, "p_patient": patient_id, "p_doctor": body.doctor_id}).execute().data
    return {"id": str(assignment_id)}


@router.delete("/patients/{patient_id}/assignments/{assignment_id}")
def end_assignment(patient_id: str, assignment_id: str, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    rows = supabase.table("patient_doctor_assignments").update({"ended_at": datetime.now(UTC).isoformat(), "ended_by": scope.actor_id, "end_reason": "centre_ended"}).eq("id", assignment_id).eq("centre_id", scope.centre_id).eq("patient_id", patient_id).is_("ended_at", "null").execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="assignment not found")
    return {"id": assignment_id, "status": "ended"}


def _clinical_record(supabase: Any, patient_id: str) -> dict:
    drafts = supabase.table("clinical_drafts").select("id,status,created_at,updated_at").eq("user_id", patient_id).execute().data or []
    reports = supabase.table("monthly_reports").select("id,status,period_start,period_end,version,reviewed_at").eq("patient_id", patient_id).execute().data or []
    return {"patient_id": patient_id, "drafts": drafts, "monthly_reports": reports, "read_only": True}


@router.get("/patients/{patient_id}/clinical-record")
def read_centre_clinical_record(patient_id: str, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    if not centre_clinical_access(supabase, scope.actor_id, scope.centre_id, patient_id):
        raise HTTPException(status_code=403, detail="clinical consent required")
    return audited_read(supabase, actor_id=scope.actor_id, actor_role="centre", patient_id=patient_id, centre_id=scope.centre_id, resource_type="clinical_record", resource_id=patient_id, read=lambda: _clinical_record(supabase, patient_id))
