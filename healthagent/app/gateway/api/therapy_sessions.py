"""Patient-owned therapy session commands."""

from typing import Annotated, Any

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field

from app.clinical.therapy_sessions import (
    SessionConflict, SessionForbidden, SessionSafetyRefused,
    add_checkin, book_session, finish_session, start_session,
)
from app.common.context_loader import ContextLoader
from app.common.supabase_client import get_supabase_client
from app.gateway.auth import current_user_id

router = APIRouter(prefix="/api/v1/therapy-sessions", tags=["therapy-sessions"])


class Booking(BaseModel):
    plan_item_id: str
    offering_id: str
    scheduled_start: str | None = None


class Finish(BaseModel):
    delivered_dose: dict = Field(default_factory=dict)


class Checkin(BaseModel):
    question_version: str
    question_ordinal: int = Field(ge=1, le=2)
    question_code: str
    answer: Any


def _call(function, *args):
    try:
        return function(*args)
    except SessionSafetyRefused as error:
        raise HTTPException(status_code=409, detail={"code": "safety_refused", "reason_codes": error.reason_codes}) from None
    except SessionForbidden as error:
        raise HTTPException(status_code=403, detail=str(error)) from None
    except SessionConflict as error:
        raise HTTPException(status_code=409, detail=str(error)) from None


@router.post("", status_code=201)
def create_booking(
    body: Booking,
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    idempotency_key: Annotated[str, Header(alias="Idempotency-Key")],
) -> dict:
    facts = ContextLoader(supabase).therapy_safety_facts(user_id)
    return _call(book_session, supabase, user_id, body.plan_item_id, body.offering_id,
                 idempotency_key, facts, body.scheduled_start)


@router.post("/{session_id}/start")
def start(session_id: str, user_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    facts = ContextLoader(supabase).therapy_safety_facts(user_id)
    return _call(start_session, supabase, user_id, session_id, facts)


@router.post("/{session_id}/finish")
def finish(session_id: str, body: Finish, user_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return _call(finish_session, supabase, user_id, session_id, body.delivered_dose)


@router.post("/{session_id}/checkins", status_code=201)
def checkin(session_id: str, body: Checkin, user_id: Annotated[str, Depends(current_user_id)], supabase: Annotated[Any, Depends(get_supabase_client)]) -> dict:
    return _call(add_checkin, supabase, user_id, session_id, body.question_version,
                 body.question_ordinal, body.question_code, body.answer)
