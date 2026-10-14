"""Super Admin operational access to an explicitly selected centre."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Header, HTTPException, Query

from app.common.supabase_client import get_supabase_client
from app.gateway.api.centre import (
    AssignmentCreate, BookingCreate, BookingTransition, CentreInvitationCreate,
    PrimaryDoctor, RoomCreate, RoomHoursCreate, ServiceCreate, StatusUpdate,
    assign_patient, create_booking, create_centre_invitation, create_room,
    create_room_hours, create_service, end_assignment, link_room_service,
    list_bookings, list_centre_doctors, list_rooms, list_services,
    operational_dashboard, operational_members, operational_transition_booking,
    set_primary_doctor, update_room_status, update_service_status,
)
from app.gateway.api.accounts import get_invitation_service
from app.gateway.auth import current_user_id
from app.gateway.invitations import InvitationService
from app.gateway.roles import ADMIN, require_app_role
from app.gateway.tenancy import CentreOwnerScope

router = APIRouter(prefix="/api/v1/admin/centres/{centre_id}/operations", tags=["admin-centre-operations"])


@dataclass(frozen=True)
class AdminOperationsScope:
    actor_id: str
    centre_id: str
    membership_id: str = "admin"

    @classmethod
    def resolve(cls, actor_id: str, centre_id: str, supabase: Any) -> "AdminOperationsScope":
        rows = supabase.table("centres").select("id").eq("id", centre_id).eq("status", "active").limit(1).execute().data or []
        if not rows:
            raise HTTPException(status_code=404, detail="centre not found")
        return cls(actor_id, centre_id)

    def centre_scope(self) -> CentreOwnerScope:
        return CentreOwnerScope(self.actor_id, self.membership_id, self.centre_id)


def require_admin_operations_scope(centre_id: str, actor_id: Annotated[str, Depends(current_user_id)], _: Annotated[str, Depends(require_app_role(ADMIN))], supabase: Annotated[Any, Depends(get_supabase_client)]) -> AdminOperationsScope:
    return AdminOperationsScope.resolve(actor_id, centre_id, supabase)


@router.get("/dashboard")
def admin_dashboard(scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return operational_dashboard(scope.centre_scope(), supabase, actor_role="admin")


@router.get("/members")
def admin_members(scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], limit: int = Query(default=100, ge=1, le=200), offset: int = Query(default=0, ge=0)) -> dict:
    return operational_members(scope.centre_scope(), supabase, limit, offset, actor_role="admin")


@router.get("/doctors")
def admin_doctors(scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], limit: int = Query(default=100, ge=1, le=200), offset: int = Query(default=0, ge=0)) -> dict:
    return list_centre_doctors(scope.centre_scope(), supabase, limit, offset)


@router.post("/invitations", status_code=201)
def admin_invitation(body: CentreInvitationCreate, scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], service: Annotated[InvitationService, Depends(get_invitation_service)], idempotency_key: Annotated[str, Header(alias="Idempotency-Key")]) -> dict:
    return create_centre_invitation(body, scope.centre_scope(), supabase, service, idempotency_key)


@router.post("/patients/{patient_id}/assignments", status_code=201)
def admin_assign_patient(patient_id: str, body: AssignmentCreate, scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return assign_patient(patient_id, body, scope.centre_scope(), supabase)


@router.patch("/patients/{patient_id}/primary-doctor")
def admin_set_primary_doctor(patient_id: str, body: PrimaryDoctor, scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return set_primary_doctor(patient_id, body, scope.centre_scope(), supabase)


@router.delete("/patients/{patient_id}/assignments/{assignment_id}")
def admin_end_assignment(patient_id: str, assignment_id: str, scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return end_assignment(patient_id, assignment_id, scope.centre_scope(), supabase)


@router.get("/rooms")
def admin_rooms(scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], limit: int = Query(default=100, ge=1, le=200), offset: int = Query(default=0, ge=0)) -> dict:
    return list_rooms(scope.centre_scope(), supabase, limit, offset)


@router.post("/rooms", status_code=201)
def admin_create_room(body: RoomCreate, scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return create_room(body, scope.centre_scope(), supabase)


@router.patch("/rooms/{room_id}/status")
def admin_update_room_status(room_id: str, body: StatusUpdate, scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return update_room_status(room_id, body, scope.centre_scope(), supabase)


@router.post("/rooms/{room_id}/hours", status_code=201)
def admin_create_room_hours(room_id: str, body: RoomHoursCreate, scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return create_room_hours(room_id, body, scope.centre_scope(), supabase)


@router.get("/services")
def admin_services(scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], limit: int = Query(default=100, ge=1, le=200), offset: int = Query(default=0, ge=0)) -> dict:
    return list_services(scope.centre_scope(), supabase, limit, offset)


@router.post("/services", status_code=201)
def admin_create_service(body: ServiceCreate, scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return create_service(body, scope.centre_scope(), supabase)


@router.patch("/services/{service_id}/status")
def admin_update_service_status(service_id: str, body: StatusUpdate, scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return update_service_status(service_id, body, scope.centre_scope(), supabase)


@router.post("/services/{service_id}/compatible-rooms/{room_id}", status_code=201)
def admin_link_room_service(service_id: str, room_id: str, scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return link_room_service(service_id, room_id, scope.centre_scope(), supabase)


@router.get("/bookings")
def admin_bookings(scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)], status: str | None = None, limit: int = Query(default=100, ge=1, le=200), offset: int = Query(default=0, ge=0)) -> dict:
    return list_bookings(scope.centre_scope(), supabase, status=status, limit=limit, offset=offset)


@router.post("/bookings", status_code=201)
def admin_create_booking(body: BookingCreate, scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return create_booking(body, scope.centre_scope(), supabase)


@router.post("/bookings/{booking_id}/transitions")
def admin_transition_booking(booking_id: str, body: BookingTransition, scope: Annotated[AdminOperationsScope, Depends(require_admin_operations_scope)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return operational_transition_booking(booking_id, body, scope.centre_scope(), supabase)
