"""What the agent may read from the clinician spine, and what it may not.

The agent holds service-role credentials and bypasses RLS by design, so the
database's "no user-facing select policy on drafts" protects the phone and the
console — not us. Here, application code is solely responsible, and the rule is
the same one the policy encodes: **the agent reads insights, never drafts.**

That matters more than it looks. The agent narrates to the user. If an
unreviewed draft reached its context, the guardrails would be the only thing
between a sentence no clinician has read and the person it is about — and the
whole point of this phase is that there is a signature in between instead.
"""

import pytest

from app.common.context_loader import ContextLoader
from tests.fakes import FakeSupabase

USER = "11111111-0000-4000-8000-000000000001"
OTHER = "22222222-0000-4000-8000-000000000002"


def insight(**overrides):
    base = {
        "id": "f1",
        "user_id": USER,
        "kind": "lab_finding",
        "title": "HbA1c has risen across 3 results",
        "body": "HbA1c has risen 11.1%, from 5.4% to 6.0%.",
        "evidence": [{"biomarker_id": "hba1c", "value_canonical": 6.0}],
        "noticed_by": "agent",
        "reviewed_at": "2026-10-09T10:00:00+00:00",
        "reviewer_name": "Dr A. Example",
        "reviewer_registration": "MCI-TEST-0001",
        "delivery_route": "clinician_signed",
        "delivered_at": "2026-10-09T10:00:05+00:00",
        "disputed_at": None,
        "dispute_reason": None,
        "dismissed_at": None,
        "withdrawn_at": None,
    }
    base.update(overrides)
    return base


def loader_with(*insights):
    return ContextLoader(FakeSupabase({"insights": list(insights)}))


# ── Scoping ──────────────────────────────────────────────────────────────────

def test_only_this_users_insights_come_back():
    loader = loader_with(insight(), insight(id="f2", user_id=OTHER))

    items = loader.clinical_insights(USER)["items"]

    assert [i["id"] for i in items] == ["f1"]


def test_newest_first():
    loader = loader_with(
        insight(id="old", delivered_at="2026-01-01T00:00:00+00:00"),
        insight(id="new", delivered_at="2026-10-01T00:00:00+00:00"),
    )

    assert [i["id"] for i in loader.clinical_insights(USER)["items"]] == ["new", "old"]


def test_no_insights_is_an_empty_list_not_a_failure():
    """"You have none" and "we could not look" are different statements, and the
    agent is told to keep them apart."""
    result = loader_with().clinical_insights(USER)

    assert result["items"] == []
    assert result.get("status") != "unconfigured"


# ── The trail travels with the insight ───────────────────────────────────────

def test_the_reviewer_is_carried():
    """An insight without its reviewer is the trail missing the only part the
    user cannot reconstruct. "A doctor reviewed this" is unverifiable;
    "Dr A. Example, MCI-TEST-0001, on 9 October" is the claim we are making."""
    item = loader_with(insight()).clinical_insights(USER)["items"][0]

    assert item["reviewer_name"] == "Dr A. Example"
    assert item["reviewer_registration"] == "MCI-TEST-0001"
    assert item["reviewed_at"]


def test_the_delivery_route_is_carried():
    """`sla_expired` means no clinician read it. The agent must be able to tell
    the user that, rather than implying a review that did not happen."""
    item = loader_with(
        insight(delivery_route="sla_expired", reviewed_at=None,
                reviewer_name=None, reviewer_registration=None)
    ).clinical_insights(USER)["items"][0]

    assert item["delivery_route"] == "sla_expired"
    assert item["reviewer_name"] is None


def test_the_evidence_is_carried():
    item = loader_with(insight()).clinical_insights(USER)["items"][0]

    assert item["evidence"]


def test_a_disputed_insight_says_so():
    """A user who disagreed with a signed insight must not have it quoted back
    at them as settled fact."""
    item = loader_with(
        insight(disputed_at="2026-10-09T11:00:00+00:00",
                dispute_reason="My doctor already knows.")
    ).clinical_insights(USER)["items"][0]

    assert item["disputed_at"]
    assert item["dispute_reason"] == "My doctor already knows."


# ── Withdrawn insights ───────────────────────────────────────────────────────

def test_a_withdrawn_insight_is_not_returned():
    """Withdrawn means it should not have been sent. Leaving it in the agent's
    context would have it narrated after being retracted."""
    loader = loader_with(insight(withdrawn_at="2026-10-09T12:00:00+00:00"))

    assert loader.clinical_insights(USER)["items"] == []


def test_a_dismissed_insight_is_still_returned():
    """Dismissed means "I have read this", not "this was wrong". It is still
    context for a conversation."""
    loader = loader_with(insight(dismissed_at="2026-10-09T12:00:00+00:00"))

    assert len(loader.clinical_insights(USER)["items"]) == 1


# ── The agent cannot reach a draft ───────────────────────────────────────────

def test_the_loader_has_no_method_that_reads_drafts():
    """The database's enforcement is the absence of a policy. Ours is the
    absence of a method: all user data is read through this one scoped loader,
    so if nothing here selects from clinical_drafts, no tool can reach one.

    If a future phase needs the console to read drafts, that is a different
    service with its own credentials — not a method here.
    """
    import inspect

    from app.common import context_loader

    source = inspect.getsource(context_loader)
    # The query construction, not the prose: the loader is allowed to explain
    # in a docstring why it does not read these tables, and the first version
    # of this test failed on exactly that sentence.
    for table in ("clinical_drafts", "clinical_reviews"):
        assert f'table("{table}")' not in source, table
        assert f"table('{table}')" not in source, table


def test_a_limit_is_honoured_and_bounded():
    loader = loader_with(*[insight(id=f"f{i}", delivered_at=f"2026-0{i}-01")
                           for i in range(1, 6)])

    assert len(loader.clinical_insights(USER, limit=2)["items"]) == 2
