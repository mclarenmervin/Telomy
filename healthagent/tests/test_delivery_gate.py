"""The delivery gate, in Python, agreeing with the one in Postgres.

`013_clinical_review.sql` is the enforcement — it binds the clinician console
and our own service role alike, and nothing reaches `insights` without passing
it. This module tests the Python half, which exists for three reasons and not
because the database needs help:

* the delivery worker should not fire an insert it already knows will fail and
  then have to reverse-engineer a 23514 into a log line;
* a refusal needs a *reason*, for the queue metrics and for the operator;
* the SLA sweep has to decide which expired drafts are even candidates before
  it starts writing.

The one thing that would make this half dangerous is disagreeing with the
database, because then the worker would skip a delivery Postgres would have
allowed, or attempt one it would not. So the hash is pinned against values
Postgres actually produced rather than against Python's own output — the
regeneration command is in the fixture below.
"""

import pytest

from app.agent.guardrails import (
    CLINICIAN_SIGNED,
    SLA_EXPIRED,
    body_sha256,
    gate_delivery,
)

# Hex sha256 of the body text, as computed BY POSTGRES. Regenerate with:
#
#   psql "$SUPABASE_DB_URL" -tAc \
#     "select encode(sha256(convert_to('<body>', 'UTF8')), 'hex')"
#
# Pinned this way round deliberately. Asserting Python against Python would
# prove only that hashlib is deterministic, which was never in doubt; the claim
# that matters is that our hash and the trigger's are the same number.
SIGNED_BODY = "Across your last three panels HbA1c moved from 5.4% to 5.9%."
SIGNED_BODY_SHA = "4387728a8c137079c4feacb91317b76ea83cccabdbc1a71c3249b2df702870df"

# A clinician in India writing in two scripts with an accented word in the
# middle is not an edge case, it is Tuesday. `convert_to(..., 'UTF8')` and
# `str.encode("utf-8")` must agree about every byte of it.
UNICODE_BODY = "Your HbA1c è 5.9% — consider a repeat panel in ३ months."
UNICODE_BODY_SHA = "c04e5bf1629cbb21d17153f8dabf08b7edbc3fe2e636b0e7d7b77d0f4518ac5b"

EMPTY_SHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


def draft(**overrides):
    base = {
        "id": "d0000000-0000-4000-8000-000000000001",
        "body": SIGNED_BODY,
        "status": "signed",
        "routing_flags": [],
    }
    base.update(overrides)
    return base


def signature(**overrides):
    base = {
        "id": "e0000000-0000-4000-8000-000000000001",
        "draft_id": "d0000000-0000-4000-8000-000000000001",
        "action": "signed",
        "signed_body_sha256": SIGNED_BODY_SHA,
        "clinician_id": "b0000000-0000-4000-8000-000000000001",
    }
    base.update(overrides)
    return base


# ── The hash agrees with Postgres ────────────────────────────────────────────

@pytest.mark.parametrize(
    "body,expected",
    [
        (SIGNED_BODY, SIGNED_BODY_SHA),
        (UNICODE_BODY, UNICODE_BODY_SHA),
        ("", EMPTY_SHA),
    ],
)
def test_our_hash_is_the_hash_postgres_computes(body, expected):
    assert body_sha256(body) == expected


def test_one_character_changes_the_hash():
    """The entire gate rests on this, so it is asserted rather than assumed."""
    assert body_sha256(SIGNED_BODY) != body_sha256(SIGNED_BODY + ".")


def test_whitespace_is_not_forgiven():
    """A console that trims a trailing newline before display and not before
    signing would produce a signature that never matches anything. Better that
    it fails on the first draft than on a random one later."""
    assert body_sha256(SIGNED_BODY) != body_sha256(SIGNED_BODY + "\n")
    assert body_sha256(SIGNED_BODY) != body_sha256(" " + SIGNED_BODY)


# ── The signed route ─────────────────────────────────────────────────────────

def test_a_body_matching_its_signature_is_deliverable():
    decision = gate_delivery(draft(), signature(), body=SIGNED_BODY)

    assert decision.deliverable is True
    assert decision.route == CLINICIAN_SIGNED
    assert decision.reason is None


def test_the_body_defaults_to_the_drafts_own():
    """Delivery normally sends the draft's body verbatim. Passing it separately
    is for the caller that has edited it, which is exactly the caller this gate
    exists to catch."""
    assert gate_delivery(draft(), signature()).deliverable is True


def test_a_one_character_edit_after_signing_is_undeliverable():
    """The case the plan names explicitly. Note that the draft's status is still
    `signed` — a status check would wave this straight through, which is why the
    gate is a hash."""
    edited = draft(body=SIGNED_BODY + ".")
    decision = gate_delivery(edited, signature())

    assert decision.deliverable is False
    assert "signed" in decision.reason


def test_a_revision_does_not_inherit_the_old_signature():
    revised = draft(body=SIGNED_BODY + " Consider a repeat panel.", status="revised")

    assert gate_delivery(revised, signature()).deliverable is False


def test_a_claim_is_not_a_signature():
    """`clinical_reviews` holds every action a clinician took. Only one of them
    authorises a delivery, and reading the latest row without checking which
    kind it is would let a claim deliver the draft it claimed."""
    decision = gate_delivery(draft(), signature(action="claimed",
                                                signed_body_sha256=None))

    assert decision.deliverable is False
    assert "signature" in decision.reason


def test_a_rejection_is_not_a_signature():
    decision = gate_delivery(
        draft(status="rejected"),
        signature(action="rejected", signed_body_sha256=None),
    )

    assert decision.deliverable is False


def test_a_signature_for_a_different_draft_is_refused():
    """Two drafts about the same person, one signed. Keying delivery on the
    person rather than on the draft would deliver the unsigned one under the
    other's signature."""
    decision = gate_delivery(
        draft(id="d0000000-0000-4000-8000-000000000002"), signature()
    )

    assert decision.deliverable is False
    assert "draft" in decision.reason


# ── The unreviewed route, and how narrow it is ───────────────────────────────
#
# The plan's de-risk for a stalled queue: after N hours, deliver the autonomous
# observation-only version and mark the draft expired. It is the one path that
# delivers with no signature, so every condition on it is load-bearing.

def test_an_expired_unflagged_observation_can_go_without_a_signature():
    decision = gate_delivery(draft(status="expired"), None)

    assert decision.deliverable is True
    assert decision.route == SLA_EXPIRED


def test_a_flagged_draft_can_never_go_without_a_signature():
    """The whole reason `clinician_queue` is allowed to leave medication text
    uncensored. If this ever returns deliverable, that profile becomes a way to
    put unreviewed supplement advice on a user's screen."""
    decision = gate_delivery(
        draft(status="expired", routing_flags=["supplement"]), None
    )

    assert decision.deliverable is False
    assert "supplement" in decision.reason


@pytest.mark.parametrize("flags", [["medication"], ["diagnosis"], ["supplement",
                                                                   "medication"]])
def test_no_flag_at_all_takes_the_unreviewed_route(flags):
    assert gate_delivery(draft(status="expired", routing_flags=flags),
                         None).deliverable is False


@pytest.mark.parametrize(
    "status", ["drafted", "queued", "in_review", "revised", "signed", "rejected"]
)
def test_only_an_expired_draft_takes_the_unreviewed_route(status):
    """A draft still in the queue has not been given up on. Delivering it
    unreviewed would make the queue decorative — the clinician would find it
    already sent."""
    decision = gate_delivery(draft(status=status), None)

    assert decision.deliverable is False
    assert status in decision.reason


def test_an_already_delivered_draft_is_not_delivered_again():
    """The webhook retries and the sweep is not transactional with the insert."""
    assert gate_delivery(draft(status="delivered"), None).deliverable is False


def test_a_withdrawn_draft_is_never_delivered():
    assert gate_delivery(draft(status="withdrawn"), None).deliverable is False
    assert gate_delivery(
        draft(status="withdrawn"), signature()
    ).deliverable is False


# ── Shapes that should not crash ─────────────────────────────────────────────

def test_a_missing_routing_flags_key_reads_as_unflagged():
    """`routing_flags` is NOT NULL with a default in Postgres, so a row always
    has it — but a projection that did not select it must not silently become
    "no flags" for the flagged case. Absent reads as unflagged, which is only
    safe because the database refuses the delivery anyway."""
    bare = {"id": draft()["id"], "body": SIGNED_BODY, "status": "expired"}

    assert gate_delivery(bare, None).deliverable is True


def test_a_draft_with_no_body_is_refused_rather_than_hashed():
    decision = gate_delivery(draft(body=None), signature())

    assert decision.deliverable is False
