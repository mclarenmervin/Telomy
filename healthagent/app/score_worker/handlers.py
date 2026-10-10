"""Turns a scheduled recompute into a stored score.

Deterministic throughout — no LLM is involved in producing a number (P2). The
worker is a thin shell around `app.analytics.scores`, which the REST endpoint
and the agent tool also call, so there is one implementation and several
callers rather than several implementations.
"""

from datetime import date
from typing import Any

from app.analytics.reference_ranges import RangeResolver
from app.analytics.scores import COMPUTERS, DEFAULT_SCORE_KIND, persist_snapshot
from app.analytics.subject import resolve_subject
from app.clinical.drafts import (
    DRAFT_JOB_KIND,
    create_drafts,
    trend_drafts,
)
from app.clinical.supplement_drafts import supplement_drafts
from app.common.context_loader import ContextLoader
from app.common.logging_config import get_logger, log_context
from app.scheduler.plan import SCORE_RECOMPUTE

logger = get_logger(__name__)

# Two years of history, as biological age uses: enough for someone who tests
# annually, and `find_trends` narrows to its own window from there.
_TREND_LOOKBACK_DAYS = 730
_TREND_ROW_LIMIT = 500



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

    score_kind = job.get("score_kind") or DEFAULT_SCORE_KIND
    compute = COMPUTERS.get(score_kind)
    if compute is None:
        logger.warning(f"no computer for score_kind {score_kind!r} {context}")
        return
    try:
        as_of = date.fromisoformat(str(raw_as_of))
    except ValueError:
        logger.warning(f"skipping score job with a bad date {raw_as_of!r} {context}")
        return

    try:
        persist_snapshot(supabase, compute(supabase, user_id, as_of))
    except Exception:
        logger.exception(
            f"scoring failed {context} kind={score_kind} as_of={as_of}"
        )


def process_draft_job(job: dict, supabase: Any) -> None:
    """Look for findings in this user's confirmed results and queue them.

    Deterministic throughout: `marker_trends` decides what fires and
    `clinical.drafts` writes the sentence. No LLM is involved -- a draft is a
    statement of arithmetic, and the clinician supplies the meaning when they
    revise it.

    Never raises. A poisoned job must not take the worker down, and a draft that
    fails to be created is a finding a clinician does not see rather than a
    number that is wrong.
    """
    user_id = job.get("user_id")
    raw_as_of = job.get("as_of")
    context = log_context(user_id=user_id)

    if not user_id or not raw_as_of:
        logger.warning(f"skipping malformed draft job {job!r}")
        return
    try:
        as_of = date.fromisoformat(str(raw_as_of))
    except ValueError:
        logger.warning(f"skipping draft job with a bad date {raw_as_of!r} {context}")
        return

    try:
        loader = ContextLoader(supabase)
        rows = loader.biomarker_results(
            user_id, days=_TREND_LOOKBACK_DAYS, limit=_TREND_ROW_LIMIT
        )["items"]
        clinic_id = loader.treating_clinic_id(user_id)
    except Exception:
        logger.exception(f"drafting failed {context} as_of={raw_as_of}")
        return

    # Two producers, two try blocks. They look at the same results and answer
    # different questions, and one of them failing must not silently take the
    # other's findings with it -- a rule file that will not load is not a reason
    # for a clinician to stop seeing trends.
    try:
        create_drafts(
            supabase,
            user_id,
            trend_drafts(rows, user_id=user_id, as_of=as_of),
            clinic_id=clinic_id,
        )
    except Exception:
        logger.exception(f"trend drafting failed {context} as_of={raw_as_of}")

    try:
        create_drafts(
            supabase,
            user_id,
            _supplement_candidates(loader, rows, user_id=user_id, as_of=as_of),
            clinic_id=clinic_id,
        )
    except Exception:
        logger.exception(f"supplement drafting failed {context} as_of={raw_as_of}")


def _supplement_candidates(loader, rows, *, user_id: str, as_of: date):
    """What the supplement producer needs that the trend producer does not.

    The rest of the person. Their date of birth and sex decide whether anything
    may be recommended to them at all, and their medications decide what the
    draft has to say -- the plan asks for medications to feed interpretation
    rather than only guardrails, and a supplement draft built without them is
    the confidently wrong version of this feature.

    The subject is resolved at `as_of` rather than at the draw date, unlike
    biological age: "is this person a minor, or pregnant" is a question about
    now, because now is when the recommendation would be made. The two dates are
    at most `HISTORY_DAYS` apart anyway, since an older deficiency produces
    nothing.
    """
    profile_rows = loader.user_profile(user_id)["items"]
    profile = (profile_rows[0].get("profile") if profile_rows else None) or {}
    resolver = RangeResolver(load_overrides=loader.range_overrides)
    subject = resolve_subject(profile, as_of)

    return supplement_drafts(
        rows,
        user_id=user_id,
        as_of=as_of,
        # Closed over here so the analytics module never sees a user id: it asks
        # for a range by marker and gets one or nothing.
        #
        # `subject.sex`, not `profile['sex']`: the profile editor offers a
        # `gender` box too, and a read of `sex` alone saw None for everyone who
        # used it -- which for ferritin is the difference between a finding and
        # silence.
        resolve=lambda marker: resolver.resolve(marker, user_id, subject.sex),
        subject=subject,
        medications=loader.safety_facts(user_id)["items"],
    )


#: What this worker knows how to do. A kind that is not here is ignored rather
#: than guessed at -- a typo must never silently become a score recompute under
#: another name.
_HANDLERS = {
    SCORE_RECOMPUTE: process_score_job,
    DRAFT_JOB_KIND: process_draft_job,
}


def process_job(job: dict, supabase: Any) -> None:
    """One job of any kind this worker handles.

    `process_score_job` stays the entry point for score work and keeps its own
    kind check, so a job reaching it directly still behaves as it did.
    """
    kind = (job or {}).get("kind")
    # A job enqueued before `kind` existed carries none, and a queue is not
    # drained at deploy time.
    handler = _HANDLERS.get(kind) if kind is not None else process_score_job
    if handler is None:
        logger.info(f"ignoring job kind {kind!r}")
        return
    handler(job, supabase)
