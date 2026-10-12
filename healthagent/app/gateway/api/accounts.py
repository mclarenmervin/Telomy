from typing import Annotated, Any

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from app.common.supabase_client import get_supabase_client
from app.gateway.auth import current_user_id
from app.gateway.invitations import (
    InvitationService,
    SupabaseAuthInvitationProvider,
    SupabaseInvitationStore,
)

router = APIRouter(prefix="/api/v1/invitations", tags=["accounts"])


class InvitationDecision(BaseModel):
    invitation_id: str


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


@router.post("/decline")
def decline_invitation(
    body: InvitationDecision,
    user_id: Annotated[str, Depends(current_user_id)],
    service: Annotated[InvitationService, Depends(get_invitation_service)],
):
    return service.result_dict(service.decline(body.invitation_id, user_id))
