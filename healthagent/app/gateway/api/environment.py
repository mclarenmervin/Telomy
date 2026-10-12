"""The environment screen's one endpoint.

Thin, like the other routers. It exists rather than having the app read
`environment_snapshots` directly — which is how the app reads scores, lab
uploads and chat history — for one reason: the AQI and UV *bands* are
computed, and computing them on the phone would be a second implementation
of a published scale. The table holds the numbers; `environment.describe`
turns them into "unhealthy" and "very high"; the phone renders.

The concierge's `get_environment` tool lands on the same loader method, so a
card and a sentence cannot disagree about what the air was doing.
"""

from typing import Annotated, Any

from fastapi import APIRouter, Depends, Query

from app.common.context_loader import ContextLoader
from app.common.supabase_client import get_supabase_client
from app.gateway.auth import current_user_id

router = APIRouter(prefix="/api/v1/environment", tags=["environment"])

#: Two weeks is what the screen shows. Longer is a chart nobody asked for,
#: and the agent's tool can reach ninety days when a question needs it.
DEFAULT_DAYS = 14
MAX_DAYS = 90


@router.get("")
def read_environment(
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    days: int = Query(default=DEFAULT_DAYS, ge=1, le=MAX_DAYS),
) -> dict:
    """Always a 200. Having no location is the normal state for most users,
    and it is a thing the screen renders rather than an error."""
    return ContextLoader(supabase).environment_snapshots(user_id, days=days)
