"""Moving the clinician queue along, once per scheduler tick.

Four moves in one pass, and the order between them is load-bearing:

1. **Offer** new drafts for review. The producer writes `drafted` because the
   state machine refuses anything else on insert, so something has to queue
   them.
2. **Return** stale claims, so a clinician who went off shift mid-review does
   not hold a draft indefinitely.
3. **Deliver** what has been signed -- *before* the SLA runs, because a signed
   draft whose SLA has also lapsed must be delivered with its signature rather
   than expired and delivered without one.
4. **Expire** what no human reached, and deliver the unflagged ones.

Never raises. The scheduler tick calls this alongside the nightly score
recompute, the lab reconciliation and the storage purge, and a sweep that dies
takes all of them with it.

Reports what it did, including `depth` and `stranded`. The plan names "the
clinician queue becomes the bottleneck and the product feels dead" as a risk
whose cheapest de-risk is instrumenting queue depth from day one; `stranded` is
the sharper number, because a flagged draft that expired can never be delivered
at all, and nothing else in the system would mention it.
"""

from datetime import datetime, timezone
from typing import Any

from app.clinical.queue_plan import (
    DELIVERABLE_STATUS,
    expired_claims,
    insight_row,
    past_sla,
)
from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)

# Enough to cover any real queue without scanning the table. A queue deeper
# than this is itself the alert.
_SWEEP_LIMIT = 500

#: Statuses that are still somebody's problem. `delivered`, `rejected` and
#: `withdrawn` are finished with and are not fetched at all.
_OPEN = ("drafted", "queued", "in_review", "revised", "signed", "expired")

#: Waiting on a human. What `depth` counts.
_WAITING = ("queued", "in_review", "revised")


def _open_drafts(supabase) -> list[dict]:
    return (
        supabase.table("clinical_drafts")
        .select(
            "id,user_id,kind,title,body,evidence,routing_flags,status,"
            "claimed_by,claimed_at,sla_due_at"
        )
        .in_("status", list(_OPEN))
        .range(0, _SWEEP_LIMIT - 1)
        .execute()
        .data
    ) or []


def _set_status(supabase, draft_id: str, values: dict) -> None:
    supabase.table("clinical_drafts").update(values).eq("id", draft_id).execute()


def _newest_signature(supabase, draft_id: str) -> dict | None:
    """The signature to deliver, which is the newest one.

    A draft revised and signed again has two signature rows, and the older one
    is over text nobody is delivering any more.
    """
    rows = (
        supabase.table("clinical_reviews")
        .select("id,draft_id,clinician_id,action,signed_body_sha256,created_at")
        .eq("draft_id", draft_id)
        .eq("action", "signed")
        .order("created_at", desc=True)
        .limit(1)
        .execute()
        .data
    )
    return rows[0] if rows else None


def _already_delivered(supabase, draft_id: str) -> bool:
    """Checked rather than left to `one_delivery_per_signature`.

    The constraint is the guarantee, but a violation would fail the statement,
    and a sweep that aborts on the first already-delivered draft never reaches
    the new one.
    """
    rows = (
        supabase.table("insights")
        .select("id")
        .eq("draft_id", draft_id)
        .limit(1)
        .execute()
        .data
    )
    return bool(rows)


def _deliver(supabase, draft: dict, review: dict | None) -> bool:
    row = insight_row(draft, review)
    if row is None:
        return False
    if _already_delivered(supabase, draft["id"]):
        return False

    supabase.table("insights").insert(row).execute()
    _set_status(supabase, draft["id"], {"status": "delivered"})
    logger.info(
        f"insight delivered {log_context(user_id=draft.get('user_id'))} "
        f"draft={draft['id']} route={row['delivery_route']}"
    )
    return True


def _standing_stranded(supabase, drafts: list[dict]) -> int:
    """Flagged drafts that expired and have no insight, however long ago.

    Counted from the same page of open drafts the sweep already read rather
    than with a second query: `_OPEN` includes `expired`, so they are all here,
    and a count that needed its own query would be a count that gets dropped
    the first time the sweep is made cheaper.
    """
    total = 0
    for draft in drafts:
        if draft.get("status") != "expired":
            continue
        if not (draft.get("routing_flags") or []):
            # It took the SLA path and the user was told. Counting it would
            # make the number mean "expired" rather than "nobody will ever
            # hear about this".
            continue
        try:
            if not _already_delivered(supabase, draft["id"]):
                total += 1
        except Exception:
            logger.exception(
                f"could not tell whether draft {draft.get('id')} is stranded"
            )
    return total


def sweep_queue(supabase: Any, now: datetime | None = None) -> dict:
    """One pass over the clinician queue. Returns what it did, for the log."""
    now = now or datetime.now(timezone.utc)
    report = {
        "queued": 0,
        "claims_expired": 0,
        "sla_expired": 0,
        "delivered": 0,
        "stranded": 0,
        "stranded_total": 0,
        "depth": 0,
    }

    try:
        drafts = _open_drafts(supabase)
    except Exception:
        logger.exception("could not read the clinician queue, will retry next tick")
        return report

    by_id = {d["id"]: d for d in drafts if d.get("id")}

    # 1 — offer new drafts for review.
    for draft in drafts:
        if draft.get("status") != "drafted":
            continue
        try:
            _set_status(supabase, draft["id"], {"status": "queued"})
            draft["status"] = "queued"
            report["queued"] += 1
        except Exception:
            logger.exception(f"could not queue draft {draft.get('id')}")

    # 2 — return stale claims.
    for draft_id in expired_claims(drafts, now):
        try:
            _set_status(
                supabase,
                draft_id,
                # Both cleared together: `claim_is_whole` requires both or
                # neither, and a draft showing a claimant who no longer holds
                # it is worse than one showing none.
                {"status": "queued", "claimed_by": None, "claimed_at": None},
            )
            by_id[draft_id]["status"] = "queued"
            by_id[draft_id]["claimed_by"] = None
            report["claims_expired"] += 1
            logger.info(f"claim expired, draft returned to the queue draft={draft_id}")
        except Exception:
            logger.exception(f"could not release the claim on draft {draft_id}")

    # 3 — deliver signatures. Before the SLA, so a signed draft whose deadline
    # has also passed is delivered with its signature rather than without one.
    for draft in drafts:
        if draft.get("status") != DELIVERABLE_STATUS:
            continue
        try:
            review = _newest_signature(supabase, draft["id"])
            if review is None:
                # The machine lets a console set `signed` without recording the
                # review, so this is the only thing that would notice.
                logger.warning(
                    f"draft {draft['id']} is signed with no signature row; "
                    "not delivering"
                )
                continue
            if _deliver(supabase, draft, review):
                draft["status"] = "delivered"
                report["delivered"] += 1
            else:
                # Left as `signed` rather than quietly moved on. Somebody has
                # to look, and advancing it would hide that the trail is broken.
                logger.warning(
                    f"draft {draft['id']} is signed but its body no longer "
                    "matches the signature; not delivering"
                )
        except Exception:
            logger.exception(f"could not deliver draft {draft.get('id')}")

    # 4 — expire what nobody reached, and deliver the unflagged ones.
    for draft_id in past_sla(drafts, now):
        draft = by_id[draft_id]
        try:
            _set_status(supabase, draft_id, {"status": "expired"})
            draft["status"] = "expired"
            report["sla_expired"] += 1

            if _deliver(supabase, draft, None):
                draft["status"] = "delivered"
                report["delivered"] += 1
            else:
                # A flagged draft that expired can never be delivered. It is
                # not an error -- the gate is working -- but it is the number
                # that says users are not being told things.
                report["stranded"] += 1
                logger.warning(
                    f"draft {draft_id} expired carrying routing flags "
                    f"{draft.get('routing_flags')} and cannot be delivered "
                    "without a signature"
                )
        except Exception:
            logger.exception(f"could not expire draft {draft_id}")

    report["depth"] = sum(1 for d in drafts if d.get("status") in _WAITING)
    # A level, where `stranded` above is a rate.
    #
    # A draft strands permanently: it is `expired`, so no later sweep considers
    # it again and `stranded` returns to zero on the next tick while the draft
    # sits there forever. The handoff says to watch this number from day one,
    # and a dashboard reading zero with forty-one people waiting is worse than
    # no dashboard at all -- so this is the one to alert on, and `stranded`
    # stays as the thing that happened just now.
    report["stranded_total"] = _standing_stranded(supabase, drafts)
    # `stranded_total` is in this list deliberately: a tick where nothing
    # happened but forty-one drafts are sitting stranded is exactly the tick
    # that needs to appear in the log.
    if any(report[k] for k in ("queued", "claims_expired", "sla_expired",
                               "delivered", "stranded", "stranded_total")):
        logger.info(f"clinical queue swept {report}")
    return report
