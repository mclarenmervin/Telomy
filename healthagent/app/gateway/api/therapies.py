"""Before/after evidence for the user's therapies, as one endpoint.

Thin, like the other routers. The concierge's `get_therapy_effects` tool calls
the same function, so a card and a sentence cannot disagree about what
somebody's sauna sessions do to them.
"""

from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, ConfigDict, Field

from app.analytics.therapy_effect import WINDOW_DAYS, for_user
from app.clinical.therapy_plans import PlanForbidden, PlanInvalid, create_plan
from app.common.context_loader import ContextLoader
from app.common.supabase_client import get_supabase_client
from app.gateway.auth import current_user_id

router = APIRouter(prefix="/api/v1/therapies", tags=["therapies"])

#: Below this there is no chance of reaching the session floor, so the window
#: would only ever answer "not enough yet".
MIN_WINDOW_DAYS = 30


class PlanProposal(BaseModel):
    model_config = ConfigDict(extra="forbid")
    centre_id: str
    items: list[dict] = Field(min_length=1, max_length=25)


@router.get("/catalogue")
def read_catalogue(
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    del user_id
    rows = supabase.table("therapy_catalogue").select(
        "id,slug,version,display_name,category,summary,intended_experience,event_type,dose_schema,contraindication_rule_ids,evidence_metadata"
    ).eq("publication_status", "published").order("display_name").execute().data or []
    return {"items": rows}


@router.get("/centres/{centre_id}/offerings")
def read_offerings(
    centre_id: str,
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    membership = supabase.table("centre_memberships").select("id").eq("centre_id", centre_id).eq("user_id", user_id).eq("status", "active").is_("left_at", "null").limit(1).execute().data or []
    if not membership:
        raise HTTPException(status_code=404, detail="centre not found")
    rows = supabase.table("centre_therapy_offerings").select("*").eq("centre_id", centre_id).eq("status", "active").execute().data or []
    catalogue_ids = [row["catalogue_id"] for row in rows]
    catalogue = supabase.table("therapy_catalogue").select("*").in_("id", catalogue_ids).eq("publication_status", "published").execute().data if catalogue_ids else []
    by_id = {str(row["id"]): row for row in (catalogue or [])}
    return {"items": [
        {**row, "price_qualifier": "Indicative", "catalogue": by_id.get(str(row["catalogue_id"]))}
        for row in rows if str(row["catalogue_id"]) in by_id
    ]}


@router.get("/plans")
def read_plans(
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    rows = supabase.table("therapy_plans").select("*").eq("patient_id", user_id).order("version", desc=True).execute().data or []
    return {"items": rows}


@router.post("/plans", status_code=201)
def propose_plan(
    body: PlanProposal,
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    try:
        facts = ContextLoader(supabase).therapy_safety_facts(user_id)
        return create_plan(supabase, user_id, body.centre_id, user_id, body.items, facts)
    except PlanForbidden as error:
        raise HTTPException(status_code=403, detail=str(error)) from None
    except PlanInvalid as error:
        raise HTTPException(status_code=422, detail=str(error)) from None


@router.get("/effects")
def read_therapy_effects(
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    days: int = Query(default=WINDOW_DAYS, ge=MIN_WINDOW_DAYS, le=WINDOW_DAYS),
) -> dict:
    """Always a 200. "You have had three saunas and we need five" is a result
    the screen must render, not an error."""
    return for_user(ContextLoader(supabase), user_id, days=days)
