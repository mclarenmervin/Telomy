"""What the clinician queue should do next, as pure functions over rows.

Same split as `scheduler/plan.py` and `scheduler/lab_sweep.py`: the decisions
are here and testable without a database, and the module that touches Postgres
is only the part that touches Postgres.

Three decisions, and the first two are the plan's named de-risks for a queue
that stalls:

**A claim expires.** A clinician who claims a draft and then goes off shift —
or whose licence lapses, or who leaves the clinic — must not hold it forever.
The draft returns to the queue for somebody else.

**The SLA expires.** After N hours with no human, an unflagged observation is
delivered anyway and the draft is marked `expired`. This is the one path to a
user that no clinician read, so what is eligible for it is the narrowest
question in the phase.

**A signature needs delivering.** Swept rather than pushed, deliberately: the
clinician console is a separate repo, and if delivery depended on that console
calling a webhook of ours, a console that signed without telling us would leave
the user's insight undelivered forever. A sweep is robust to any console.
"""

from datetime import datetime, timedelta, timezone

from app.clinical.queue_plan import (
    CLAIM_TTL_HOURS,
    expired_claims,
    insight_row,
    past_sla,
)

NOW = datetime(2026, 10, 10, 12, 0, tzinfo=timezone.utc)
USER = "11111111-0000-4000-8000-000000000001"
DOCTOR = "b2b2b2b2-0000-4000-8000-000000000001"


def ts(**delta):
    return (NOW - timedelta(**delta)).isoformat()


def draft(**overrides):
    base = {
        "id": "d0000000-0000-4000-8000-000000000001",
        "user_id": USER,
        "kind": "lab_finding",
        "title": "HbA1c has risen across 3 results",
        "body": "HbA1c has risen 11.1%, from 5.4% to 6.0%.",
        "evidence": [{"biomarker_id": "hba1c", "value_canonical": 6.0}],
        "routing_flags": [],
        "status": "signed",
        "claimed_by": DOCTOR,
        "claimed_at": ts(minutes=10),
        "sla_due_at": (NOW + timedelta(hours=48)).isoformat(),
    }
    base.update(overrides)
    return base


def signature(**overrides):
    base = {
        "id": "e0000000-0000-4000-8000-000000000001",
        "draft_id": "d0000000-0000-4000-8000-000000000001",
        "clinician_id": DOCTOR,
        "action": "signed",
        "signed_body_sha256":
            "d99cd9f7e4b9d31b22b0e1a0f5e12cf5a4f7d2e8c4c7c4e3b1f8a9d0c2b3a4e5",
        "created_at": ts(minutes=5),
    }
    base.update(overrides)
    return base


# ── Claims expire ────────────────────────────────────────────────────────────

def test_a_fresh_claim_does_not_expire():
    assert expired_claims([draft(status="in_review", claimed_at=ts(minutes=30))],
                          now=NOW) == []


def test_a_stale_claim_expires():
    stale = draft(status="in_review", claimed_at=ts(hours=CLAIM_TTL_HOURS + 1))

    assert expired_claims([stale], now=NOW) == [stale["id"]]


def test_the_ttl_boundary_is_the_published_one():
    just_inside = draft(id="a", status="in_review",
                        claimed_at=ts(hours=CLAIM_TTL_HOURS, minutes=-5))
    just_outside = draft(id="b", status="in_review",
                         claimed_at=ts(hours=CLAIM_TTL_HOURS, minutes=5))

    assert expired_claims([just_inside, just_outside], now=NOW) == ["b"]


def test_only_a_claimed_draft_can_have_its_claim_expire():
    """A queued draft has no claim to lose, and a signed one is finished with.
    Resetting either would move a draft backwards through the machine."""
    for status in ("drafted", "queued", "revised", "signed", "rejected",
                   "expired", "delivered", "withdrawn"):
        rows = [draft(status=status, claimed_at=ts(hours=CLAIM_TTL_HOURS + 1))]

        assert expired_claims(rows, now=NOW) == [], status


def test_a_draft_in_review_with_no_claim_is_not_a_claim_to_expire():
    """The `claim_is_whole` constraint should make this impossible, so reaching
    for `claimed_at` without checking would be a crash on a row that cannot
    exist — until a migration or a console makes it exist."""
    rows = [draft(status="in_review", claimed_by=None, claimed_at=None)]

    assert expired_claims(rows, now=NOW) == []


def test_an_unparseable_claim_time_does_not_expire_the_claim():
    """Loud failure is not available here: the sweep runs unattended. Leaving it
    claimed means a human has to look, which is the better of the two errors."""
    rows = [draft(status="in_review", claimed_at="not a timestamp")]

    assert expired_claims(rows, now=NOW) == []


# ── The SLA expires ──────────────────────────────────────────────────────────

def test_a_draft_within_its_sla_is_not_expired():
    assert past_sla([draft(status="queued")], now=NOW) == []


def test_a_draft_past_its_sla_is_expired():
    overdue = draft(status="queued", sla_due_at=ts(hours=1))

    assert past_sla([overdue], now=NOW) == [overdue["id"]]


def test_a_draft_under_review_is_past_its_sla_too():
    """A clinician who claimed it and never came back should not hold the user's
    insight indefinitely. The claim expiry returns it to the queue and the SLA
    runs independently, so a draft repeatedly claimed and abandoned still
    eventually reaches the user."""
    overdue = draft(status="in_review", sla_due_at=ts(hours=1))

    assert past_sla([overdue], now=NOW) == [overdue["id"]]


def test_a_revised_draft_is_past_its_sla_too():
    overdue = draft(status="revised", sla_due_at=ts(hours=1))

    assert past_sla([overdue], now=NOW) == [overdue["id"]]


def test_a_signed_draft_is_never_sla_expired():
    """It has a human's signature on it. Expiring it would replace a reviewed
    insight with an unreviewed one, which is the exact opposite of the point."""
    assert past_sla([draft(status="signed", sla_due_at=ts(hours=1))], now=NOW) == []


def test_a_rejected_draft_is_never_sla_expired():
    """A clinician said no. Delivering it anyway because the clock ran out would
    make the review worse than useless."""
    assert past_sla([draft(status="rejected", sla_due_at=ts(hours=1))],
                    now=NOW) == []


def test_an_already_expired_or_delivered_draft_is_not_expired_again():
    for status in ("expired", "delivered", "withdrawn"):
        assert past_sla([draft(status=status, sla_due_at=ts(hours=1))],
                        now=NOW) == [], status


def test_a_draft_with_no_sla_deadline_never_expires():
    """Rather than defaulting to "overdue". A null deadline is a draft something
    created without one, and guessing would deliver it unreviewed immediately."""
    assert past_sla([draft(status="queued", sla_due_at=None)], now=NOW) == []


# ── Building the insight ─────────────────────────────────────────────────────

def test_a_signed_draft_becomes_an_insight():
    body = draft()["body"]
    row = insight_row(draft(), signature(signed_body_sha256=_sha(body)))

    assert row["user_id"] == USER
    assert row["draft_id"] == draft()["id"]
    assert row["review_id"] == signature()["id"]
    assert row["body"] == body
    assert row["kind"] == "lab_finding"
    assert row["delivery_route"] == "clinician_signed"


def test_the_evidence_travels_to_the_insight():
    """The user is entitled to the same workings the clinician saw. An insight
    whose evidence was dropped at delivery is a claim with no trail."""
    row = insight_row(draft(), signature(signed_body_sha256=_sha(draft()["body"])))

    assert row["evidence"] == draft()["evidence"]


def test_the_reviewer_is_not_named_by_us():
    """`reviewed_by`, `reviewer_name` and `reviewer_registration` are stamped by
    the database from the signature it can see, so the trail cannot be addressed
    to a clinician who did not sign. Sending them from here would be the caller
    asserting what the gate is there to establish."""
    row = insight_row(draft(), signature(signed_body_sha256=_sha(draft()["body"])))

    assert "reviewed_by" not in row
    assert "reviewer_name" not in row
    assert "reviewer_registration" not in row


def test_a_mismatched_signature_produces_no_row():
    """The gate, reached through the same function the database mirrors. A
    sweep that built the row anyway would hand Postgres an insert it is
    guaranteed to refuse, once per tick, forever."""
    assert insight_row(draft(body="edited after signing"), signature()) is None


def test_an_expired_unflagged_draft_becomes_an_unreviewed_insight():
    row = insight_row(draft(status="expired"), None)

    assert row["review_id"] is None
    assert row["delivery_route"] == "sla_expired"
    assert row["noticed_by"] == "agent"


def test_an_expired_flagged_draft_produces_no_row():
    assert insight_row(
        draft(status="expired", routing_flags=["supplement"]), None
    ) is None


def test_a_queued_draft_produces_no_unreviewed_row():
    assert insight_row(draft(status="queued"), None) is None


def _sha(body: str) -> str:
    from app.agent.guardrails import body_sha256

    return body_sha256(body)
