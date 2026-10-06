"""Turns a scheduled recompute into a stored score.

Deterministic throughout — no LLM is involved in producing a number (P2). The
worker is a thin shell around `app.analytics.scores`, which the REST endpoint
and the agent tool also call, so there is one implementation and several
callers rather than several implementations.
"""

from datetime import date
from typing import Any

from app.analytics.scores import compute_readiness, persist_snapshot
from app.common.logging_config import get_logger, log_context
from app.scheduler.plan import SCORE_RECOMPUTE

logger = get_logger(__name__)


def process_score_job(job: dict, supabase: Any) -> None:
    """One job. Never raises: a poisoned job must not take the worker down."""
    user_id = job.get("user_id")
    raw_as_of = job.get("as_of")
    context = log_context(user_id=user_id)

    if job.get("kind") not in (None, SCORE_RECOMPUTE):
        logger.info(f"ignoring job kind {job.get('kind')!r} {context}")
        return
    if not user_id or not raw_as_of:
        logger.warning(f"skipping malformed score job {job!r}")
        return
    try:
        as_of = date.fromisoformat(str(raw_as_of))
    except ValueError:
        logger.warning(f"skipping score job with a bad date {raw_as_of!r} {context}")
        return

    try:
        snapshot = compute_readiness(supabase, user_id, as_of)
        persist_snapshot(supabase, snapshot)
    except Exception:
        logger.exception(f"scoring failed {context} as_of={as_of}")
