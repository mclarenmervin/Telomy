"""Deterministic score reads for the app.

Thin by design. Every handler resolves the caller from the verified token, loads
through the shared service, and returns — all real logic stays in
`app/analytics`, which the score worker and the agent's tools also call. That is
what makes "one implementation, two callers" true rather than aspirational, and
it is what stops a chart and a sentence disagreeing about the same number.

**The caller is never a parameter.** There is no `user_id` in any path, query or
body here; it comes from the token only, exactly as the agent's tools take it
from state. A user cannot ask for someone else's scores because there is nothing
to tamper with.
"""

from datetime import date
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Query

from app.analytics.scores import COMPUTERS, persist_snapshot
from app.common.logging_config import get_logger, log_context
from app.common.supabase_client import get_supabase_client
from app.gateway.auth import current_user_id

router = APIRouter(prefix="/api/v1/scores", tags=["scores"])
logger = get_logger(__name__)

# Only kinds we can actually produce. An unknown kind is a 422 from FastAPI
# rather than an empty result that reads like "you have no score", and the list
# comes from `scores.COMPUTERS` so this cannot claim a score nothing computes.
ScoreKind = Literal["readiness", "biological_age"]

assert set(ScoreKind.__args__) == set(COMPUTERS), (
    "the REST surface and the score registry disagree about which kinds exist"
)


def _latest(supabase, user_id: str, kind: str, as_of: date | None) -> dict | None:
    query = (
        supabase.table("score_snapshots")
        .select("*")
        .eq("user_id", user_id)
        .eq("score_kind", kind)
    )
    if as_of is not None:
        query = query.eq("as_of_date", as_of.isoformat())
    rows = query.order("as_of_date", desc=True).limit(1).execute().data
    return rows[0] if rows else None


@router.get("/{kind}")
def read_score(
    kind: ScoreKind,
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    as_of: date | None = Query(default=None),
) -> dict:
    """The stored score for a day, or the most recent one."""
    snapshot = _latest(supabase, user_id, kind, as_of)
    if snapshot is None:
        # 404 rather than a zero: "we have not computed this" and "your score is
        # nothing" are different statements.
        raise HTTPException(status_code=404, detail="no score for that day yet")
    return snapshot


@router.post("/{kind}/recompute")
def recompute_score(
    kind: ScoreKind,
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    as_of: date = Query(...),
) -> dict:
    """Recompute now, for when the user has just confirmed new data and should
    not have to wait for tonight's sweep."""
    snapshot = COMPUTERS[kind](supabase, user_id, as_of)
    persist_snapshot(supabase, snapshot)
    logger.info(f"score recomputed on request {log_context(user_id=user_id)} kind={kind}")
    return snapshot
