"""What the clinician queue should do next, as pure functions over rows.

The same split `scheduler/plan.py` and `scheduler/lab_sweep.py` use: the
decisions live here and are testable without a database, and the module that
touches Postgres is only the part that touches Postgres.

### Why delivery is swept rather than pushed

There is no webhook on a signature, and that is deliberate. The clinician
console is a separate repo doing CRUD over Postgres with RLS. If delivery
depended on that console calling an endpoint of ours, then a console that
signed without telling us -- a new version, a different vendor, a bug -- would
leave the user's insight undelivered forever, with a valid signature sitting in
the database and nothing to notice. A sweep over `signed` drafts with no
insight is robust to any console, needs no new service, and costs at most one
scheduler tick of latency against a review that took hours.

### Why a claim and the SLA expire independently

A clinician who claims a draft and goes off shift holds it; the claim expiry
returns it to the queue for somebody else. The SLA clock runs from when the
draft was created and is not reset by a claim, so a draft repeatedly claimed
and abandoned still eventually reaches the user rather than cycling forever
between the two sweeps.
"""

from datetime import datetime, timedelta

from app.agent.guardrails import (
    CLINICIAN_SIGNED,
    SLA_EXPIRED,
    gate_delivery,
)
from app.common.timeparse import parse_ts

#: How long a clinician may hold a claim before it returns to the queue. Long
#: enough to read a panel, make a call and write a revision; short enough that
#: going off shift mid-review does not strand the draft until tomorrow.
CLAIM_TTL_HOURS = 4

#: Statuses from which a claim can expire. Only one, but naming it keeps the
#: rule beside the machine it belongs to.
_CLAIMABLE = ("in_review",)

#: Statuses the SLA clock still applies to. Deliberately excludes `signed` and
#: `rejected`: a human has dealt with those, and expiring them would replace a
#: reviewed decision with an unreviewed one -- the exact opposite of the point.
_SLA_PENDING = ("queued", "in_review", "revised")

#: Statuses with a signature waiting to be delivered.
DELIVERABLE_STATUS = "signed"


def expired_claims(rows, now: datetime) -> list[str]:
    """Drafts whose claim has gone stale, oldest claim first.

    A clinician whose licence lapses or who leaves the clinic mid-review is the
    same case as one who simply stopped: `clinician_may_sign` would refuse the
    signature, so the draft has to come back to the queue or it is stuck in
    their name indefinitely.
    """
    cutoff = now - timedelta(hours=CLAIM_TTL_HOURS)
    stale = []
    for row in rows or []:
        if row.get("status") not in _CLAIMABLE:
            continue
        # The `claim_is_whole` constraint should make a half-claim impossible,
        # so this is guarding against a row that cannot exist -- until a
        # migration or a console makes it exist.
        if not row.get("claimed_by") or not row.get("claimed_at"):
            continue
        claimed_at = parse_ts(row.get("claimed_at"))
        if claimed_at is None:
            # The sweep runs unattended, so there is nobody to fail loudly at.
            # Leaving it claimed means a human has to look at it, which is the
            # better of the two errors.
            continue
        if claimed_at < cutoff:
            stale.append((claimed_at, row["id"]))
    return [draft_id for _, draft_id in sorted(stale)]


def past_sla(rows, now: datetime) -> list[str]:
    """Drafts no clinician reached in time, longest overdue first."""
    overdue = []
    for row in rows or []:
        if row.get("status") not in _SLA_PENDING:
            continue
        due = parse_ts(row.get("sla_due_at"))
        if due is None:
            # A null deadline is a draft created without one. Defaulting to
            # "overdue" would deliver it unreviewed immediately, which is the
            # worst available reading of a missing value.
            continue
        if due < now:
            overdue.append((due, row["id"]))
    return [draft_id for _, draft_id in sorted(overdue)]


def insight_row(draft: dict, review: dict | None) -> dict | None:
    """The `insights` row this draft should become, or None if it may not.

    None comes from `gate_delivery`, so this and the database agree by
    construction rather than by both being written carefully. A sweep that
    built the row anyway would hand Postgres an insert it is guaranteed to
    refuse, once per tick, forever.

    The reviewer is deliberately absent. `reviewed_by`, `reviewer_name` and
    `reviewer_registration` are stamped by the trigger from the signature it
    can see, so the trail cannot be addressed to a clinician who did not sign;
    sending them from here would be the caller asserting the very thing the
    gate exists to establish.
    """
    decision = gate_delivery(draft, review)
    if not decision.deliverable:
        return None

    row = {
        "user_id": draft["user_id"],
        "draft_id": draft["id"],
        "review_id": review["id"] if review else None,
        "kind": draft["kind"],
        "title": draft["title"],
        "body": draft["body"],
        # The user is entitled to the same workings the clinician saw. An
        # insight whose evidence was dropped at delivery is a claim with no
        # trail, which is what this phase exists to stop being the case.
        "evidence": draft.get("evidence") or [],
        "noticed_by": "agent",
        "delivery_route": decision.route,
    }
    if decision.route == CLINICIAN_SIGNED:
        # The trigger coalesces a null to the signature's own timestamp. Sent
        # explicitly so the row satisfies `reviewer_is_whole` on its own terms
        # and the constraint is not relying on trigger ordering.
        row["reviewed_at"] = review.get("created_at")
    elif decision.route == SLA_EXPIRED:
        row["reviewed_at"] = None
    return row
