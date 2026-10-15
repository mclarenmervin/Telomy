"""Doctor workspace API, always scoped to an explicit centre and assignment."""

from __future__ import annotations

import hashlib
from datetime import UTC, date, datetime
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from pydantic import BaseModel, Field, field_validator

from app.clinical.monthly_reports import compose_monthly_report
from app.clinical.queue_plan import therapy_plan_queue_rows
from app.clinical.summaries import compose_patient_summary
from app.common.supabase_client import get_supabase_client
from app.gateway.api.accounts import get_invitation_service
from app.gateway.auth import current_user_id
from app.gateway.doctor_loader import DoctorLoader
from app.gateway.invitations import InvitationService
from app.gateway.roles import DOCTOR, require_app_role

router = APIRouter(prefix="/api/v1/doctor", tags=["doctor"])


@router.get("/profile")
def doctor_profile(
    doctor_id: Annotated[str, Depends(current_user_id)],
    _: Annotated[str, Depends(require_app_role(DOCTOR))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    clinicians = supabase.table("clinicians").select("registration_number,status,licence_expires_at,full_name").eq("user_id", doctor_id).limit(1).execute().data or []
    verification = supabase.table("clinician_verifications").select("status,registration_body,specialties,created_at").eq("doctor_id", doctor_id).order("created_at", desc=True).limit(1).execute().data or []
    return {
        **(clinicians[0] if clinicians else {}),
        "verification_status": verification[0].get("status") if verification else "pending",
        "registration_body": verification[0].get("registration_body") if verification else None,
        "specialties": verification[0].get("specialties") if verification else [],
    }


class NonEmptyNote(BaseModel):
    note: str = Field(min_length=1, max_length=4000)

    @field_validator("note")
    @classmethod
    def trim_note(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("note is required")
        return value


class ClinicalDecision(NonEmptyNote):
    version: str
    body: str | None = None


class NoteCreate(BaseModel):
    body: str = Field(min_length=1, max_length=8000)
    supersedes_id: str | None = None

    @field_validator("body")
    @classmethod
    def trim_body(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("note body is required")
        return value


class PatientInvitation(BaseModel):
    email: str = Field(min_length=3, max_length=320)
    primary: bool = True


class ReportGenerate(BaseModel):
    patient_id: str
    period_start: date
    period_end: date
    source_cutoff: datetime
    period_label: str = Field(min_length=1, max_length=80)


def _loader(supabase: Any, doctor_id: str, centre_id: str) -> DoctorLoader:
    return DoctorLoader.for_actor(supabase, doctor_id, centre_id)


@router.get("/centres")
def doctor_centres(
    doctor_id: Annotated[str, Depends(current_user_id)],
    _: Annotated[str, Depends(require_app_role(DOCTOR))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    memberships = supabase.table("centre_memberships").select("centre_id,status,accepted_at").eq("user_id", doctor_id).eq("member_kind", "doctor").eq("status", "active").is_("left_at", "null").execute().data or []
    ids = [row["centre_id"] for row in memberships]
    centres = supabase.table("centres").select("id,name,status").in_("id", ids).execute().data if ids else []
    return {"items": centres or []}


@router.get("/{centre_id}/today")
def doctor_today(centre_id: str, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    loader = _loader(supabase, doctor_id, centre_id)
    patients = loader.patients()
    drafts = loader.drafts()
    patient_ids = [row["id"] for row in patients]
    escalations = supabase.table("lab_escalations").select("id,user_id,created_at").in_("user_id", patient_ids).is_("acknowledged_at", "null").execute().data if patient_ids else []
    return {"centre_id": centre_id, "patient_count": len(patients), "pending_work": len(drafts), "critical_escalations": escalations or []}


@router.get("/{centre_id}/patients")
def doctor_patients(centre_id: str, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)], query: str | None = None) -> dict:
    patients = _loader(supabase, doctor_id, centre_id).patients()
    if query:
        needle = query.strip().lower()
        patients = [row for row in patients if needle in str(row.get("full_name") or "").lower()]
    return {"items": patients}


@router.get("/{centre_id}/patients/{patient_id}")
def doctor_patient(centre_id: str, patient_id: str, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return _loader(supabase, doctor_id, centre_id).patient(patient_id)


@router.get("/{centre_id}/patients/{patient_id}/summary")
def doctor_patient_summary(centre_id: str, patient_id: str, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    patient = _loader(supabase, doctor_id, centre_id).patient(patient_id)
    summary = compose_patient_summary({"patient_name": patient.get("full_name"), "period": "the last 7 days", "metrics": []})
    return {"patient_id": patient_id, "text": summary.text, "evidence": [item.__dict__ for item in summary.evidence]}


@router.get("/{centre_id}/patients/{patient_id}/reports")
def doctor_patient_reports(centre_id: str, patient_id: str, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    _loader(supabase, doctor_id, centre_id).patient(patient_id)
    rows = supabase.table("monthly_reports").select("id,period_start,period_end,source_cutoff,evidence,body,version,status,supersedes_id,reviewer_note,signed_by,reviewed_at,signed_body_sha256,created_at").eq("centre_id", centre_id).eq("patient_id", patient_id).order("period_end", desc=True).execute().data or []
    return {"items": rows}


@router.get("/{centre_id}/patients/{patient_id}/notes")
def doctor_patient_notes(centre_id: str, patient_id: str, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    _loader(supabase, doctor_id, centre_id).patient(patient_id)
    rows = supabase.table("clinician_notes").select("id,body,author_doctor_id,supersedes_id,created_at,withdrawn_at,withdrawal_reason").eq("centre_id", centre_id).eq("patient_id", patient_id).order("created_at", desc=True).execute().data or []
    return {"items": rows}


@router.post("/{centre_id}/patients/{patient_id}/notes", status_code=201)
def add_note(centre_id: str, patient_id: str, body: NoteCreate, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    _loader(supabase, doctor_id, centre_id).patient(patient_id)
    note_id = supabase.rpc("append_clinician_note", {"p_actor": doctor_id, "p_centre": centre_id, "p_patient": patient_id, "p_body": body.body, "p_supersedes": body.supersedes_id}).execute().data
    return {"id": str(note_id)}


@router.post("/{centre_id}/patient-invitations", status_code=201)
def invite_patient(centre_id: str, body: PatientInvitation, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)], service: Annotated[InvitationService, Depends(get_invitation_service)], idempotency_key: Annotated[str, Header(alias="Idempotency-Key")]) -> dict:
    _loader(supabase, doctor_id, centre_id)
    result = service.invite(doctor_id, body.email, "member", centre_id, doctor_id if body.primary else None, idempotency_key)
    return service.result_dict(result)


@router.get("/{centre_id}/work-queue")
def doctor_work_queue(centre_id: str, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    loader = _loader(supabase, doctor_id, centre_id)
    patient_ids = loader._patient_ids()
    reports = supabase.table("monthly_reports").select("id,patient_id,period_start,period_end,version,status,created_at").eq("centre_id", centre_id).in_("patient_id", patient_ids).in_("status", ["draft", "in_review"]).execute().data if patient_ids else []
    drafts = [row for row in loader.drafts() if row.get("status") in ("queued", "revised", "in_review")]
    plans = supabase.table("therapy_plans").select("id,patient_id,centre_id,status,version,content_sha256,proposed_by,created_at").eq("centre_id", centre_id).in_("patient_id", patient_ids).in_("status", ["proposed", "in_review"]).execute().data if patient_ids else []
    return {"monthly_reports": reports or [], "sync_drafts": drafts, "consults": [], "therapy_plans": therapy_plan_queue_rows(plans), "rx_supplements": []}


def _find_draft(loader: DoctorLoader, draft_id: str) -> dict:
    draft = next((row for row in loader.drafts() if str(row.get("id")) == draft_id), None)
    if not draft:
        raise HTTPException(status_code=404, detail="work item not found")
    return draft


@router.post("/{centre_id}/work/{draft_id}/claim")
def claim_work(centre_id: str, draft_id: str, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    draft = _find_draft(_loader(supabase, doctor_id, centre_id), draft_id)
    if draft.get("status") not in ("queued", "revised"):
        raise HTTPException(status_code=409, detail="work item is not claimable")
    now = datetime.now(UTC).isoformat()
    rows = supabase.table("clinical_drafts").update({"status": "in_review", "claimed_by": doctor_id, "claimed_at": now}).eq("id", draft_id).eq("status", draft["status"]).execute().data
    if not rows:
        raise HTTPException(status_code=409, detail="work item changed")
    supabase.table("clinical_reviews").insert({"draft_id": draft_id, "clinician_id": doctor_id, "action": "claimed"}).execute()
    return {"id": draft_id, "status": "in_review"}


@router.post("/{centre_id}/work/{draft_id}/release")
def release_work(centre_id: str, draft_id: str, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    draft = _find_draft(_loader(supabase, doctor_id, centre_id), draft_id)
    if draft.get("status") != "in_review" or draft.get("claimed_by") != doctor_id:
        raise HTTPException(status_code=409, detail="work item is not held by this doctor")
    supabase.table("clinical_drafts").update({"status": "queued", "claimed_by": None, "claimed_at": None}).eq("id", draft_id).eq("claimed_by", doctor_id).execute()
    return {"id": draft_id, "status": "queued"}


def _decide_draft(centre_id: str, draft_id: str, body: ClinicalDecision, doctor_id: str, supabase: Any, action: str) -> dict:
    draft = _find_draft(_loader(supabase, doctor_id, centre_id), draft_id)
    if str(draft.get("updated_at")) != body.version:
        raise HTTPException(status_code=409, detail="work item changed; reload before deciding")
    if draft.get("status") != "in_review" or draft.get("claimed_by") != doctor_id:
        raise HTTPException(status_code=409, detail="work item is not held by this doctor")
    delivery_body = body.body.strip() if body.body is not None else str(draft["body"])
    if not delivery_body:
        raise HTTPException(status_code=422, detail="body is required")
    if delivery_body != draft["body"]:
        supabase.table("clinical_drafts").update({"body": delivery_body, "status": "revised"}).eq("id", draft_id).execute()
        supabase.table("clinical_drafts").update({"status": "in_review"}).eq("id", draft_id).execute()
    review = {"draft_id": draft_id, "clinician_id": doctor_id, "action": action, "notes": body.note}
    if action == "signed":
        review["signed_body_sha256"] = hashlib.sha256(delivery_body.encode()).hexdigest()
    inserted = supabase.table("clinical_reviews").insert(review).execute().data or [review]
    supabase.table("clinical_drafts").update({"status": action}).eq("id", draft_id).execute()
    return {"id": draft_id, "status": action, "review": inserted[0]}


@router.post("/{centre_id}/work/{draft_id}/sign")
def sign_work(centre_id: str, draft_id: str, body: ClinicalDecision, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return _decide_draft(centre_id, draft_id, body, doctor_id, supabase, "signed")


@router.post("/{centre_id}/work/{draft_id}/reject")
def reject_work(centre_id: str, draft_id: str, body: ClinicalDecision, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return _decide_draft(centre_id, draft_id, body, doctor_id, supabase, "rejected")


@router.post("/{centre_id}/reports/generate", status_code=201)
def generate_report(centre_id: str, body: ReportGenerate, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    _loader(supabase, doctor_id, centre_id).patient(body.patient_id)
    facts: list[dict[str, Any]] = []
    report = compose_monthly_report(body.period_label, facts, body.source_cutoff)
    report_id = supabase.rpc("create_monthly_report_version", {"p_actor": doctor_id, "p_centre": centre_id, "p_patient": body.patient_id, "p_period_start": body.period_start.isoformat(), "p_period_end": body.period_end.isoformat(), "p_source_cutoff": body.source_cutoff.isoformat(), "p_evidence": list(report.evidence), "p_body": report.body}).execute().data
    return {"id": str(report_id), "body": report.body, "evidence": list(report.evidence)}


def _report_for_doctor(supabase: Any, doctor_id: str, centre_id: str, report_id: str) -> dict:
    rows = supabase.table("monthly_reports").select("id,patient_id,centre_id,status,version").eq("id", report_id).eq("centre_id", centre_id).limit(1).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="report not found")
    _loader(supabase, doctor_id, centre_id).patient(str(rows[0]["patient_id"]))
    return rows[0]


@router.post("/{centre_id}/reports/{report_id}/sign")
def sign_report(centre_id: str, report_id: str, body: ClinicalDecision, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    report = _report_for_doctor(supabase, doctor_id, centre_id, report_id)
    if str(report["version"]) != body.version:
        raise HTTPException(status_code=409, detail="report changed; reload before signing")
    digest = supabase.rpc("sign_monthly_report", {"p_actor": doctor_id, "p_report": report_id, "p_note": body.note}).execute().data
    return {"id": report_id, "status": "signed", "signed_body_sha256": str(digest)}


@router.post("/{centre_id}/reports/{report_id}/reject")
def reject_report(centre_id: str, report_id: str, body: ClinicalDecision, doctor_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    report = _report_for_doctor(supabase, doctor_id, centre_id, report_id)
    if str(report["version"]) != body.version:
        raise HTTPException(status_code=409, detail="report changed; reload before rejecting")
    supabase.table("monthly_reports").update({"status": "rejected", "reviewer_note": body.note, "reviewed_at": datetime.now(UTC).isoformat()}).eq("id", report_id).execute()
    return {"id": report_id, "status": "rejected"}
