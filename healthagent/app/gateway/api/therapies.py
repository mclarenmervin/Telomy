"""Before/after evidence for the user's therapies, as one endpoint.

Thin, like the other routers. The concierge's `get_therapy_effects` tool calls
the same function, so a card and a sentence cannot disagree about what
somebody's sauna sessions do to them.
"""

from typing import Annotated, Any

from fastapi import APIRouter, Depends, Query

from app.analytics.therapy_effect import WINDOW_DAYS, for_user
from app.common.context_loader import ContextLoader
from app.common.supabase_client import get_supabase_client
from app.gateway.auth import current_user_id

router = APIRouter(prefix="/api/v1/therapies", tags=["therapies"])

#: Below this there is no chance of reaching the session floor, so the window
#: would only ever answer "not enough yet".
MIN_WINDOW_DAYS = 30


@router.get("/effects")
def read_therapy_effects(
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    days: int = Query(default=WINDOW_DAYS, ge=MIN_WINDOW_DAYS, le=WINDOW_DAYS),
) -> dict:
    """Always a 200. "You have had three saunas and we need five" is a result
    the screen must render, not an error."""
    return for_user(ContextLoader(supabase), user_id, days=days)
