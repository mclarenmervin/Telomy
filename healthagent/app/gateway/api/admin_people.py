"""Super Admin centre and people management APIs."""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from pydantic import BaseModel, Field

from app.common.supabase_client import get_supabase_client
from app.gateway.access_audit import audited_read
from app.gateway.auth import current_user_id
from app.gateway.invitations import InvitationService
from app.gateway.api.accounts import get_invitation_service
from app.gateway.roles import ADMIN, require_app_role
from app.gateway.tenancy import admin_patient_access

router = APIRouter(prefix="/api/v1/admin", tags=["admin-people"])


class CentreCreate(BaseModel):
    name: str = Field(min_length=1, max_length=160)
    owner_id: str | None = None


class CentreStatus(BaseModel):
    status: Literal["active", "suspended", "closed"]


class InvitationCreate(BaseModel):
    email: str = Field(min_length=3, max_length=320)
    intended_role: Literal["admin", "centre", "doctor", "member"]
    centre_id: str | None = None
    primary_doctor_id: str | None = None


class VerificationDecision(BaseModel):
    status: Literal["verified", "rejected", "expired"]
    reason: str = Field(min_length=1, max_length=2000)
    registration_number: str | None = None
    registration_body: str | None = None
    licence_expires_at: str | None = None
    specialties: list[str] = Field(default_factory=list)


@router.post("/centres", status_code=201)
def create_centre(
    body: CentreCreate,
    actor_id: Annotated[str, Depends(current_user_id)],
    _: Annotated[str, Depends(require_app_role(ADMIN))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    centre_id = supabase.rpc(
        "create_centre", {"p_name": body.name.strip(), "p_actor": actor_id}
    ).execute().data
    return {"id": str(centre_id), "name": body.name.strip()}


@router.get("/centres")
def list_centres(
    _: Annotated[str, Depends(require_app_role(ADMIN))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    limit: int = Query(default=100, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
) -> dict:
    rows = (
        supabase.table("centres")
        .select("id,name,status,created_at,updated_at")
        .order("name")
        .range(offset, offset + limit - 1)
        .execute().data or []
    )
    return {"items": rows, "limit": limit, "offset": offset}


@router.patch("/centres/{centre_id}/status")
def update_centre_status(
    centre_id: str,
    body: CentreStatus,
    _: Annotated[str, Depends(require_app_role(ADMIN))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    rows = supabase.table("centres").update({"status": body.status}).eq("id", centre_id).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="centre not found")
    return {"id": centre_id, "status": body.status}


@router.post("/invitations", status_code=201)
def create_admin_invitation(
    body: InvitationCreate,
    actor_id: Annotated[str, Depends(current_user_id)],
    _: Annotated[str, Depends(require_app_role(ADMIN))],
    service: Annotated[InvitationService, Depends(get_invitation_service)],
    idempotency_key: Annotated[str, Header(alias="Idempotency-Key")],
) -> dict:
    result = service.invite(
        actor_id, body.email, body.intended_role, body.centre_id,
        body.primary_doctor_id, idempotency_key,
    )
    return service.result_dict(result)


@router.get("/invitations")
def list_admin_invitations(
    _: Annotated[str, Depends(require_app_role(ADMIN))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    limit: int = Query(default=100, ge=1, le=200),
) -> dict:
    rows = (
        supabase.table("account_invitations")
        .select("id,email,intended_role,centre_id,status,expires_at,created_at")
        .order("created_at", desc=True).limit(limit).execute().data or []
    )
    return {"items": rows}


@router.post("/clinicians/{doctor_id}/verification-decisions", status_code=201)
def decide_verification(
    doctor_id: str,
    body: VerificationDecision,
    actor_id: Annotated[str, Depends(current_user_id)],
    _: Annotated[str, Depends(require_app_role(ADMIN))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    decision_id = supabase.rpc("record_clinician_verification", {
        "p_actor": actor_id,
        "p_doctor": doctor_id,
        "p_status": body.status,
        "p_reason": body.reason.strip(),
        "p_registration_number": body.registration_number,
        "p_registration_body": body.registration_body,
        "p_licence_expires_at": body.licence_expires_at,
        "p_specialties": body.specialties,
    }).execute().data
    return {"id": str(decision_id), "doctor_id": doctor_id, "status": body.status}


@router.get("/patients")
def list_admin_patients(
    _: Annotated[str, Depends(require_app_role(ADMIN))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    limit: int = Query(default=100, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
) -> dict:
    rows = (
        supabase.table("profiles").select("id,full_name,email,created_at")
        .eq("app_role", "member").range(offset, offset + limit - 1).execute().data or []
    )
    return {"items": rows, "limit": limit, "offset": offset}


@router.get("/patients/{patient_id}")
def read_admin_patient(
    patient_id: str,
    actor_id: Annotated[str, Depends(current_user_id)],
    _: Annotated[str, Depends(require_app_role(ADMIN))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    if not admin_patient_access(supabase, actor_id, patient_id):
        raise HTTPException(status_code=404, detail="patient not found")
    rows = supabase.table("profiles").select("id,full_name,email,created_at").eq("id", patient_id).limit(1).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="patient not found")
    return rows[0]


def _clinical_record(supabase: Any, patient_id: str) -> dict:
    drafts = supabase.table("clinical_drafts").select("id,status,created_at,updated_at").eq("user_id", patient_id).execute().data or []
    reports = supabase.table("monthly_reports").select("id,status,period_start,period_end,version,reviewed_at").eq("patient_id", patient_id).execute().data or []
    return {"patient_id": patient_id, "drafts": drafts, "monthly_reports": reports, "read_only": True}


@router.get("/patients/{patient_id}/clinical-record")
def read_admin_clinical_record(
    patient_id: str,
    actor_id: Annotated[str, Depends(current_user_id)],
    _: Annotated[str, Depends(require_app_role(ADMIN))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    if not admin_patient_access(supabase, actor_id, patient_id):
        raise HTTPException(status_code=404, detail="patient not found")
    return audited_read(
        supabase, actor_id=actor_id, actor_role="admin", patient_id=patient_id,
        centre_id=None, resource_type="clinical_record", resource_id=patient_id,
        read=lambda: _clinical_record(supabase, patient_id),
    )


@router.get("/access-audit")
def list_access_audit(
    _: Annotated[str, Depends(require_app_role(ADMIN))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    limit: int = Query(default=100, ge=1, le=500),
) -> dict:
    rows = supabase.table("access_audit").select("id,actor_id,actor_role,action,patient_id,centre_id,resource_kind,resource_id,reason,request_id,outcome,created_at").order("created_at", desc=True).limit(limit).execute().data or []
    return {"items": rows}
