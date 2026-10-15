"""Membership-scoped Centre Owner operational APIs."""

from __future__ import annotations

from datetime import UTC, date, datetime, time
import uuid
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from pydantic import BaseModel, Field

from app.analytics.centre_metrics import calculate_centre_metrics
from app.common.supabase_client import get_supabase_client
from app.gateway.access_audit import audited_read
from app.gateway.api.accounts import get_invitation_service
from app.gateway.auth import current_user_id
from app.gateway.centre_loader import CentreLoader
from app.gateway.invitations import InvitationService
from app.gateway.roles import CENTRE, require_app_role
from app.gateway.tenancy import CentreOwnerScope, centre_clinical_access, require_centre_owner_scope

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


class RoomCreate(BaseModel):
    name: str = Field(min_length=1, max_length=160)


class RoomHoursCreate(BaseModel):
    weekday: int = Field(ge=0, le=6)
    opens_at: time
    closes_at: time
    valid_from: date
    valid_until: date | None = None


class ServiceCreate(BaseModel):
    name: str = Field(min_length=1, max_length=160)
    description: str | None = Field(default=None, max_length=2000)
    duration_minutes: int = Field(ge=5, le=1440)
    indicative_price_minor: int = Field(ge=0)
    currency_code: str = Field(min_length=3, max_length=3, pattern=r"^[A-Za-z]{3}$")


class StatusUpdate(BaseModel):
    status: Literal["active", "inactive"]


class TherapyOfferingCreate(BaseModel):
    catalogue_id: str
    service_id: str | None = None
    indicative_price_minor: int = Field(ge=0)
    currency_code: str = Field(min_length=3, max_length=3, pattern=r"^[A-Z]{3}$")
    default_duration_minutes: int | None = Field(default=None, ge=1, le=1440)
    operational_notes: str | None = Field(default=None, max_length=2000)


class BookingCreate(BaseModel):
    patient_id: str
    service_id: str
    room_id: str
    scheduled_start: datetime


class BookingTransition(BaseModel):
    command: Literal["check_in", "complete", "mark_no_show", "cancel"]
    expected_version: int = Field(ge=0)
    reason: str | None = Field(default=None, max_length=1000)


def _page(limit: int, offset: int) -> tuple[int, int]:
    if not 1 <= limit <= 200 or offset < 0:
        raise ValueError("pagination is outside the permitted range")
    return limit, offset


def _slice(rows: list[dict], limit: int, offset: int) -> list[dict]:
    _page(limit, offset)
    return rows[offset : offset + limit]


def _error_code(error: Exception) -> str:
    for attribute in ("code", "sqlstate"):
        value = getattr(error, attribute, None)
        if value:
            return str(value)
    details = getattr(error, "details", None)
    if isinstance(details, dict) and details.get("code"):
        return str(details["code"])
    return ""


def _rpc(supabase: Any, name: str, params: dict[str, Any]) -> Any:
    try:
        return supabase.rpc(name, params).execute().data
    except Exception as error:
        code = _error_code(error)
        if code == "P0002":
            raise HTTPException(status_code=404, detail="resource not found") from None
        if code == "42501":
            raise HTTPException(status_code=403, detail="not permitted") from None
        if code in {"22023", "23P01", "23505", "23514", "40001", "55000"}:
            raise HTTPException(status_code=409, detail="operation conflicts with current state") from None
        raise


def _scoped(rows: list[dict], object_id: str, detail: str) -> dict:
    row = next((row for row in rows if str(row.get("id")) == object_id), None)
    if row is None:
        raise HTTPException(status_code=404, detail=detail)
    return dict(row)


def _loader(supabase: Any, scope: CentreOwnerScope, *, actor_role: str = "centre") -> CentreLoader:
    return CentreLoader(supabase, scope, actor_role=actor_role)


def operational_dashboard(scope: CentreOwnerScope, supabase: Any, *, actor_role: str = "centre") -> dict:
    settings = supabase.table("centres").select("id,name,timezone_name,currency_code").eq("id", scope.centre_id).eq("status", "active").limit(1).execute().data or []
    if not settings:
        raise HTTPException(status_code=404, detail="centre not found")
    loader = _loader(supabase, scope, actor_role=actor_role)
    members = loader.member_snapshot()
    metrics = calculate_centre_metrics(
        timezone_name=settings[0].get("timezone_name") or "UTC",
        currency_code=settings[0].get("currency_code") or "INR",
        now=datetime.now(UTC),
        bookings=loader.bookings(), services=loader.services(), rooms=loader.rooms(),
        room_hours=loader.room_hours(), room_services=loader.room_services(), members=members["items"],
    )
    return {"centre": settings[0], **metrics}


def operational_members(scope: CentreOwnerScope, supabase: Any, limit: int, offset: int, *, actor_role: str = "centre") -> dict:
    snapshot = _loader(supabase, scope, actor_role=actor_role).member_snapshot()
    return {**snapshot, "items": _slice(snapshot["items"], limit, offset), "limit": limit, "offset": offset}


@router.get("/mine")
def my_centres(actor_id: Annotated[str, Depends(current_user_id)], _: Annotated[str, Depends(require_app_role(CENTRE))], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    memberships = supabase.table("centre_memberships").select("id,centre_id").eq("user_id", actor_id).eq("member_kind", "owner").eq("status", "active").is_("left_at", "null").execute().data or []
    ids = [row["centre_id"] for row in memberships]
    rows = supabase.table("centres").select("id,name,status,timezone_name,currency_code").in_("id", ids).eq("status", "active").execute().data if ids else []
    membership_by_centre = {row["centre_id"]: row["id"] for row in memberships}
    return {"items": [{**row, "membership_id": membership_by_centre[row["id"]]} for row in (rows or [])]}


@router.get("/dashboard")
def centre_dashboard(scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return operational_dashboard(scope, supabase)


@router.get("/members")
def list_members(scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], limit: int = Query(default=100, ge=1, le=200), offset: int = Query(default=0, ge=0)) -> dict:
    return operational_members(scope, supabase, limit, offset)


@router.get("/doctors")
def list_centre_doctors(scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], limit: int = Query(default=100, ge=1, le=200), offset: int = Query(default=0, ge=0)) -> dict:
    return {"items": _slice(_loader(supabase, scope).doctors(limit=200), limit, offset), "limit": limit, "offset": offset}


@router.get("/patients")
def list_centre_patients(scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], limit: int = Query(default=100, ge=1, le=200), offset: int = Query(default=0, ge=0)) -> dict:
    return {"items": _slice(_loader(supabase, scope).patients(limit=200), limit, offset), "limit": limit, "offset": offset}


@router.get("/therapy-offerings")
def list_therapy_offerings(scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return {"items": _loader(supabase, scope).therapy_offerings(), "price_qualifier": "Indicative"}


@router.post("/therapy-offerings", status_code=201)
def create_therapy_offering(body: TherapyOfferingCreate, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    catalogue = supabase.table("therapy_catalogue").select("id").eq("id", body.catalogue_id).eq("publication_status", "published").limit(1).execute().data or []
    if not catalogue:
        raise HTTPException(status_code=422, detail="published therapy catalogue entry required")
    row = {
        "id": str(uuid.uuid4()), "centre_id": scope.centre_id,
        "catalogue_id": body.catalogue_id, "service_id": body.service_id,
        "status": "active", "indicative_price_minor": body.indicative_price_minor,
        "currency_code": body.currency_code, "default_duration_minutes": body.default_duration_minutes,
        "operational_notes": body.operational_notes, "created_by": scope.actor_id,
        "updated_by": scope.actor_id,
    }
    inserted = supabase.table("centre_therapy_offerings").insert(row).execute().data or [row]
    return {**inserted[0], "price_qualifier": "Indicative"}


@router.get("/therapy-sessions")
def list_therapy_sessions(scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return {"items": _loader(supabase, scope).therapy_sessions()}


@router.post("/invitations", status_code=201)
def create_centre_invitation(body: CentreInvitationCreate, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], service: Annotated[InvitationService, Depends(get_invitation_service)], idempotency_key: Annotated[str, Header(alias="Idempotency-Key")]) -> dict:
    del supabase
    result = service.invite(scope.actor_id, body.email, body.intended_role, scope.centre_id, body.primary_doctor_id, idempotency_key)
    return service.result_dict(result)


@router.post("/patients/{patient_id}/assignments", status_code=201)
def assign_patient(patient_id: str, body: AssignmentCreate, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    value = _rpc(supabase, "assign_patient_doctor", {"p_actor": scope.actor_id, "p_centre": scope.centre_id, "p_patient": patient_id, "p_doctor": body.doctor_id, "p_primary": body.primary})
    return {"id": str(value)}


@router.patch("/patients/{patient_id}/primary-doctor")
def set_primary_doctor(patient_id: str, body: PrimaryDoctor, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    value = _rpc(supabase, "set_primary_doctor", {"p_actor": scope.actor_id, "p_centre": scope.centre_id, "p_patient": patient_id, "p_doctor": body.doctor_id})
    return {"id": str(value)}


@router.delete("/patients/{patient_id}/assignments/{assignment_id}")
def end_assignment(patient_id: str, assignment_id: str, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    rows = supabase.table("patient_doctor_assignments").update({"ended_at": datetime.now(UTC).isoformat(), "ended_by": scope.actor_id, "end_reason": "centre_ended"}).eq("id", assignment_id).eq("centre_id", scope.centre_id).eq("patient_id", patient_id).is_("ended_at", "null").execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="assignment not found")
    return {"id": assignment_id, "status": "ended"}


@router.get("/rooms")
def list_rooms(scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], limit: int = Query(default=100, ge=1, le=200), offset: int = Query(default=0, ge=0)) -> dict:
    loader = _loader(supabase, scope)
    return {"items": _slice(loader.rooms(), limit, offset), "room_hours": loader.room_hours(), "limit": limit, "offset": offset}


@router.post("/rooms", status_code=201)
def create_room(body: RoomCreate, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    value = _rpc(supabase, "create_centre_room", {"p_actor": scope.actor_id, "p_centre": scope.centre_id, "p_name": body.name.strip()})
    return {"id": str(value)}


@router.patch("/rooms/{room_id}/status")
def update_room_status(room_id: str, body: StatusUpdate, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    _scoped(_loader(supabase, scope).rooms(), room_id, "room not found")
    value = _rpc(supabase, "set_centre_room_status", {"p_actor": scope.actor_id, "p_centre": scope.centre_id, "p_room": room_id, "p_status": body.status})
    return {"id": str(value), "status": body.status}


@router.post("/rooms/{room_id}/hours", status_code=201)
def create_room_hours(room_id: str, body: RoomHoursCreate, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    _scoped(_loader(supabase, scope).rooms(), room_id, "room not found")
    value = _rpc(supabase, "add_centre_room_hours", {"p_actor": scope.actor_id, "p_centre": scope.centre_id, "p_room": room_id, "p_weekday": body.weekday, "p_opens_at": body.opens_at.isoformat(), "p_closes_at": body.closes_at.isoformat(), "p_valid_from": body.valid_from.isoformat(), "p_valid_until": body.valid_until.isoformat() if body.valid_until else None})
    return {"id": str(value)}


@router.delete("/rooms/{room_id}/hours/{hours_id}")
def end_room_hours(room_id: str, hours_id: str, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    hours = _scoped(_loader(supabase, scope).room_hours(), hours_id, "room hours not found")
    if str(hours.get("room_id")) != room_id:
        raise HTTPException(status_code=404, detail="room hours not found")
    value = _rpc(supabase, "end_centre_room_hours", {"p_actor": scope.actor_id, "p_centre": scope.centre_id, "p_hours": hours_id, "p_valid_until": date.today().isoformat()})
    return {"id": str(value), "status": "ended"}


@router.get("/services")
def list_services(scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], limit: int = Query(default=100, ge=1, le=200), offset: int = Query(default=0, ge=0)) -> dict:
    loader = _loader(supabase, scope)
    return {"items": _slice(loader.services(), limit, offset), "compatibility": loader.room_services(), "limit": limit, "offset": offset}


@router.post("/services", status_code=201)
def create_service(body: ServiceCreate, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    value = _rpc(supabase, "create_centre_service", {"p_actor": scope.actor_id, "p_centre": scope.centre_id, "p_name": body.name.strip(), "p_description": body.description, "p_duration_minutes": body.duration_minutes, "p_indicative_price_minor": body.indicative_price_minor, "p_currency_code": body.currency_code.upper()})
    return {"id": str(value)}


@router.patch("/services/{service_id}/status")
def update_service_status(service_id: str, body: StatusUpdate, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    _scoped(_loader(supabase, scope).services(), service_id, "service not found")
    value = _rpc(supabase, "set_centre_service_status", {"p_actor": scope.actor_id, "p_centre": scope.centre_id, "p_service": service_id, "p_status": body.status})
    return {"id": str(value), "status": body.status}


@router.post("/services/{service_id}/compatible-rooms/{room_id}", status_code=201)
def link_room_service(service_id: str, room_id: str, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    loader = _loader(supabase, scope)
    _scoped(loader.services(), service_id, "service not found")
    _scoped(loader.rooms(), room_id, "room not found")
    value = _rpc(supabase, "link_centre_room_service", {"p_actor": scope.actor_id, "p_centre": scope.centre_id, "p_room": room_id, "p_service": service_id})
    return {"id": str(value)}


@router.delete("/services/{service_id}/compatible-rooms/{room_id}")
def unlink_room_service(service_id: str, room_id: str, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    loader = _loader(supabase, scope)
    _scoped(loader.services(), service_id, "service not found")
    _scoped(loader.rooms(), room_id, "room not found")
    value = _rpc(supabase, "unlink_centre_room_service", {"p_actor": scope.actor_id, "p_centre": scope.centre_id, "p_room": room_id, "p_service": service_id})
    return {"id": str(value), "status": "ended"}


@router.get("/bookings")
def list_bookings(scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], status: str | None = None, date_from: datetime | None = None, date_to: datetime | None = None, limit: int = Query(default=100, ge=1, le=200), offset: int = Query(default=0, ge=0)) -> dict:
    rows = _loader(supabase, scope).bookings()
    if status:
        rows = [row for row in rows if row.get("status") == status]
    if date_from:
        rows = [row for row in rows if row.get("scheduled_start") and str(row["scheduled_start"]) >= date_from.isoformat()]
    if date_to:
        rows = [row for row in rows if row.get("scheduled_start") and str(row["scheduled_start"]) < date_to.isoformat()]
    rows.sort(key=lambda row: (str(row.get("scheduled_start") or ""), str(row.get("id") or "")))
    return {"items": _slice(rows, limit, offset), "limit": limit, "offset": offset}


@router.post("/bookings", status_code=201)
def create_booking(body: BookingCreate, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    value = _rpc(supabase, "create_centre_booking", {"p_actor": scope.actor_id, "p_centre": scope.centre_id, "p_patient": body.patient_id, "p_service": body.service_id, "p_room": body.room_id, "p_scheduled_start": body.scheduled_start.isoformat()})
    return _scoped(_loader(supabase, scope).bookings(), str(value), "booking not found")


@router.post("/bookings/{booking_id}/transitions")
def transition_booking(booking_id: str, body: BookingTransition, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return operational_transition_booking(booking_id, body, scope, supabase)


def operational_transition_booking(booking_id: str, body: BookingTransition, scope: CentreOwnerScope, supabase: Any, *, verify_scoped: bool = True) -> dict:
    if verify_scoped:
        _scoped(_loader(supabase, scope).bookings(), booking_id, "booking not found")
    value = _rpc(supabase, "transition_centre_booking", {"p_actor": scope.actor_id, "p_centre": scope.centre_id, "p_booking": booking_id, "p_command": body.command, "p_expected_version": body.expected_version, "p_reason": body.reason})
    return _scoped(_loader(supabase, scope).bookings(), str(value), "booking not found")


def _clinical_record(supabase: Any, patient_id: str) -> dict:
    drafts = supabase.table("clinical_drafts").select("id,status,created_at,updated_at").eq("user_id", patient_id).execute().data or []
    reports = supabase.table("monthly_reports").select("id,status,period_start,period_end,version,reviewed_at").eq("patient_id", patient_id).execute().data or []
    return {"patient_id": patient_id, "drafts": drafts, "monthly_reports": reports, "read_only": True}


@router.get("/patients/{patient_id}/clinical-record")
def read_centre_clinical_record(patient_id: str, scope: Annotated[CentreOwnerScope, Depends(require_centre_owner_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    if not centre_clinical_access(supabase, scope.actor_id, scope.centre_id, patient_id):
        raise HTTPException(status_code=403, detail="clinical consent required")
    return audited_read(supabase, actor_id=scope.actor_id, actor_role="centre", patient_id=patient_id, centre_id=scope.centre_id, resource_type="clinical_record", resource_id=patient_id, read=lambda: _clinical_record(supabase, patient_id))
