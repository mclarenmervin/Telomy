"""The correlation screen's one endpoint.

Thin, like the other routers: the caller comes from the verified token, the
work is `app/analytics/correlations.py`, and nothing here decides anything.
The concierge's `get_correlations` tool calls the same function, which is what
stops a card and a sentence disagreeing about the same two series.

**The caller is never a parameter.** No `user_id` in the path, the query or
the body — it comes from the token only.
"""

from typing import Annotated, Any

from fastapi import APIRouter, Depends, Query

from app.analytics.correlations import WINDOW_DAYS, for_user
from app.common.context_loader import ContextLoader
from app.common.supabase_client import get_supabase_client
from app.gateway.auth import current_user_id

router = APIRouter(prefix="/api/v1/correlations", tags=["correlations"])

#: The shortest window the screen offers. Below a month there is not enough
#: for the engine to report anything, and offering a button that can only
#: produce "nothing found" is worse than not offering it.
MIN_WINDOW_DAYS = 30


@router.get("")
def read_correlations(
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    days: int = Query(default=WINDOW_DAYS, ge=MIN_WINDOW_DAYS, le=WINDOW_DAYS),
) -> dict:
    """Every declared hypothesis tested against this person's days.

    Always a 200, including when nothing is reportable. "We tested five pairs
    and none held" is a result the screen must be able to render, and a 404
    would have it say the feature is broken instead.
    """
    return for_user(ContextLoader(supabase), user_id, days=days)
