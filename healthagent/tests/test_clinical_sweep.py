"""The sweep that moves the clinician queue along.

One pass per scheduler tick. It offers new drafts for review, returns stale
claims, expires drafts no human reached, and delivers what has been signed.

The decisions are all in `queue_plan` and tested there. This is about the
database contact: that each move is made, that none of them is made twice, and
that a failure in one does not stop the others — a sweep that dies takes the
whole scheduler tick with it, and that stops every scheduled thing in the
product.

It also reports queue depth, because "the clinician queue becomes the
bottleneck and the product feels dead" is a named risk whose cheapest de-risk
is instrumenting it from day one. `stranded` is the number that matters most:
flagged drafts that expired and can therefore never be delivered at all. A
rising `stranded` means users are not being told things and no alert anywhere
else would say so.
"""

from datetime import datetime, timedelta, timezone

from app.agent.guardrails import body_sha256
from app.clinical.queue_plan import CLAIM_TTL_HOURS
from app.clinical.sweep import sweep_queue
from tests.fakes import FakeSupabase

NOW = datetime(2026, 10, 10, 12, 0, tzinfo=timezone.utc)
USER = "11111111-0000-4000-8000-000000000001"
DOCTOR = "b2b2b2b2-0000-4000-8000-000000000001"
BODY = "HbA1c has risen 11.1%, from 5.4% to 6.0%."


def ts(**delta):
    return (NOW - timedelta(**delta)).isoformat()


def draft(did="d1", **overrides):
    base = {
        "id": did,
        "user_id": USER,
        "kind": "lab_finding",
        "title": "HbA1c has risen across 3 results",
        "body": BODY,
        "evidence": [{"biomarker_id": "hba1c", "value_canonical": 6.0}],
        "routing_flags": [],
        "status": "drafted",
        "claimed_by": None,
        "claimed_at": None,
        "sla_due_at": (NOW + timedelta(hours=48)).isoformat(),
    }
    base.update(overrides)
    return base


def signature(did="d1", rid="e1", body=BODY, **overrides):
    base = {
        "id": rid,
        "draft_id": did,
        "clinician_id": DOCTOR,
        "action": "signed",
        "signed_body_sha256": body_sha256(body),
        "created_at": ts(minutes=5),
    }
    base.update(overrides)
    return base


def db_with(drafts=(), reviews=(), insights=()):
    return FakeSupabase(tables={
        "clinical_drafts": list(drafts),
        "clinical_reviews": list(reviews),
        "insights": list(insights),
    })


def status_of(db, did="d1"):
    return next(r for r in db.tables["clinical_drafts"] if r["id"] == did)["status"]


# ── Offering a draft for review ──────────────────────────────────────────────

def test_a_new_draft_is_queued_for_review():
    """The producer writes `drafted` because the state machine refuses anything
    else on insert. Something has to offer it, and this is that something."""
    db = db_with([draft()])

    report = sweep_queue(db, now=NOW)

    assert status_of(db) == "queued"
    assert report["queued"] == 1


def test_an_already_queued_draft_is_not_queued_again():
    db = db_with([draft(status="queued")])

    assert sweep_queue(db, now=NOW)["queued"] == 0


# ── Returning stale claims ───────────────────────────────────────────────────

def test_a_stale_claim_returns_the_draft_to_the_queue():
    db = db_with([draft(status="in_review", claimed_by=DOCTOR,
                        claimed_at=ts(hours=CLAIM_TTL_HOURS + 1))])

    report = sweep_queue(db, now=NOW)
    row = db.tables["clinical_drafts"][0]

    assert row["status"] == "queued"
    assert report["claims_expired"] == 1


def test_releasing_a_claim_clears_the_claimant():
    """`claim_is_whole` requires both or neither, so leaving the name behind
    would make the row unupdatable afterwards — and would show the draft as
    claimed by somebody who no longer has it."""
    db = db_with([draft(status="in_review", claimed_by=DOCTOR,
                        claimed_at=ts(hours=CLAIM_TTL_HOURS + 1))])

    sweep_queue(db, now=NOW)
    row = db.tables["clinical_drafts"][0]

    assert row["claimed_by"] is None
    assert row["claimed_at"] is None


def test_a_fresh_claim_is_left_alone():
    db = db_with([draft(status="in_review", claimed_by=DOCTOR,
                        claimed_at=ts(minutes=20))])

    sweep_queue(db, now=NOW)

    assert status_of(db) == "in_review"


# ── Delivering a signature ───────────────────────────────────────────────────

def test_a_signed_draft_is_delivered():
    db = db_with([draft(status="signed")], [signature()])

    report = sweep_queue(db, now=NOW)

    assert report["delivered"] == 1
    assert len(db.tables["insights"]) == 1
    assert db.tables["insights"][0]["body"] == BODY
    assert db.tables["insights"][0]["review_id"] == "e1"
    assert status_of(db) == "delivered"


def test_a_signed_draft_is_not_delivered_twice():
    """The sweep runs every tick. Without this the user gets the same sentence
    once a minute until somebody notices."""
    db = db_with([draft(status="signed")], [signature()])

    sweep_queue(db, now=NOW)
    second = sweep_queue(db, now=NOW)

    assert second["delivered"] == 0
    assert len(db.tables["insights"]) == 1


def test_a_body_edited_after_signing_is_not_delivered():
    """The gate. The draft still says `signed`, so a status check would deliver
    this — and the hash is what refuses it."""
    db = db_with([draft(status="signed", body=BODY + " And another thing.")],
                 [signature()])

    report = sweep_queue(db, now=NOW)

    assert report["delivered"] == 0
    assert db.tables["insights"] == []
    # Left as signed rather than quietly marked delivered. Somebody has to
    # look, and moving it on would hide that the trail is broken.
    assert status_of(db) == "signed"


def test_a_signed_draft_with_no_signature_row_is_not_delivered():
    """Belt and braces against a console that set the status without recording
    the review — the state machine permits the transition, so only this notices."""
    db = db_with([draft(status="signed")], [])

    assert sweep_queue(db, now=NOW)["delivered"] == 0
    assert db.tables["insights"] == []


def test_the_newest_signature_is_the_one_delivered():
    """A draft revised and signed again has two signature rows, and the older
    one is over text nobody is delivering any more."""
    old = signature(rid="e_old", body="an earlier version")
    new = signature(rid="e_new", created_at=ts(minutes=1))
    db = db_with([draft(status="signed")], [old, new])

    sweep_queue(db, now=NOW)

    assert db.tables["insights"][0]["review_id"] == "e_new"


def test_a_claim_is_not_mistaken_for_a_signature():
    db = db_with(
        [draft(status="signed")],
        [{"id": "e_claim", "draft_id": "d1", "clinician_id": DOCTOR,
          "action": "claimed", "signed_body_sha256": None,
          "created_at": ts(minutes=1)}],
    )

    assert sweep_queue(db, now=NOW)["delivered"] == 0


# ── The SLA, and how narrow the unreviewed path is ───────────────────────────

def test_an_overdue_draft_is_expired():
    db = db_with([draft(status="queued", sla_due_at=ts(hours=1))])

    report = sweep_queue(db, now=NOW)

    assert report["sla_expired"] == 1


def test_an_overdue_unflagged_observation_is_delivered_unreviewed():
    """The plan's de-risk for a stalled queue, and it must happen in the same
    pass — expiring without delivering would mean the user hears nothing and
    the draft is now in a state no clinician will ever look at."""
    db = db_with([draft(status="queued", sla_due_at=ts(hours=1))])

    report = sweep_queue(db, now=NOW)

    assert report["delivered"] == 1
    assert db.tables["insights"][0]["review_id"] is None
    assert db.tables["insights"][0]["delivery_route"] == "sla_expired"
    assert status_of(db) == "delivered"


def test_an_overdue_flagged_draft_is_expired_but_never_delivered():
    """The one place the escape hatch must not reach. A supplement
    recommendation nobody read does not go to a user because a clock ran out."""
    db = db_with([draft(status="queued", sla_due_at=ts(hours=1),
                        routing_flags=["supplement"], kind="supplement")])

    report = sweep_queue(db, now=NOW)

    assert report["delivered"] == 0
    assert db.tables["insights"] == []
    assert status_of(db) == "expired"


def test_a_stranded_draft_is_counted():
    """The metric that matters most. A flagged draft that expired can never be
    delivered at all, so a rising `stranded` means users are not being told
    things and nothing else in the system would say so."""
    db = db_with([draft(status="queued", sla_due_at=ts(hours=1),
                        routing_flags=["supplement"], kind="supplement")])

    assert sweep_queue(db, now=NOW)["stranded"] == 1


def test_a_signed_draft_is_not_sla_expired_in_the_same_pass():
    """Order matters: if the SLA ran first and expired a signed draft, a
    clinician's signature would be replaced by an unreviewed delivery."""
    db = db_with([draft(status="signed", sla_due_at=ts(hours=1))], [signature()])

    sweep_queue(db, now=NOW)

    assert status_of(db) == "delivered"
    assert db.tables["insights"][0]["review_id"] == "e1"


def test_a_rejected_draft_is_left_alone_entirely():
    db = db_with([draft(status="rejected", sla_due_at=ts(hours=1))])

    report = sweep_queue(db, now=NOW)

    assert status_of(db) == "rejected"
    assert db.tables["insights"] == []
    assert report["delivered"] == 0


# ── Instrumentation ──────────────────────────────────────────────────────────

def test_the_queue_depth_is_reported():
    db = db_with([
        draft("d1", status="queued"),
        draft("d2", status="queued"),
        draft("d3", status="in_review", claimed_by=DOCTOR, claimed_at=ts(minutes=5)),
        draft("d4", status="delivered"),
    ])

    report = sweep_queue(db, now=NOW)

    # Waiting on a human: queued plus under review, not the finished one.
    assert report["depth"] == 3


def test_an_empty_queue_is_a_clean_report():
    report = sweep_queue(db_with(), now=NOW)

    assert report == {"queued": 0, "claims_expired": 0, "sla_expired": 0,
                      "delivered": 0, "stranded": 0, "stranded_total": 0,
                      "depth": 0}


# ── Robustness ───────────────────────────────────────────────────────────────

def test_a_failure_reading_the_queue_does_not_raise():
    """The scheduler tick calls this. A sweep that raises stops the nightly
    score recompute, the lab reconciliation and the storage purge with it."""
    class Broken(FakeSupabase):
        def table(self, name):
            raise RuntimeError("postgres is having a moment")

    assert sweep_queue(Broken(), now=NOW)["depth"] == 0


def test_one_bad_draft_does_not_stop_the_others():
    """A draft missing a field a projection should have supplied must not cost
    every other user their delivery."""
    db = db_with(
        [{"id": "broken", "status": "signed"}, draft("d2", status="signed")],
        [signature(did="d2", rid="e2")],
    )

    report = sweep_queue(db, now=NOW)

    assert report["delivered"] == 1
    assert db.tables["insights"][0]["draft_id"] == "d2"


# ── A rate is not a level ────────────────────────────────────────────────────
#
# `stranded` counts the drafts that stranded *on this tick*, which is a rate.
# A draft strands permanently: it is already `expired`, so no later sweep
# considers it again, and the counter goes back to zero on the next tick while
# the draft sits there forever.
#
# Found while seeding the demo for a device check: one stranded supplement
# draft, and the sweep that is supposed to be the alarm reported nothing. The
# handoff says to watch this number from day one, and a dashboard showing zero
# with forty-one people waiting is worse than no dashboard -- so the sweep also
# reports the standing total, which is the number somebody would actually alert
# on.

def test_a_draft_that_stranded_on_an_earlier_tick_is_still_counted():
    db = db_with([draft(status="expired", sla_due_at=ts(hours=48),
                        routing_flags=["medication"], kind="supplement")])

    report = sweep_queue(db, now=NOW)

    assert report["stranded"] == 0, "it did not strand on this tick"
    assert report["stranded_total"] == 1, "but it is still stranded"


def test_the_standing_total_includes_the_ones_that_just_stranded():
    """Otherwise the two numbers disagree on the tick that matters most."""
    db = db_with([draft(status="queued", sla_due_at=ts(hours=1),
                        routing_flags=["medication"], kind="supplement")])

    report = sweep_queue(db, now=NOW)

    assert report["stranded"] == 1
    assert report["stranded_total"] == 1


def test_a_delivered_draft_is_not_stranded():
    db = db_with(
        [draft(status="expired", sla_due_at=ts(hours=48),
               routing_flags=["medication"], kind="supplement")],
        insights=[{"id": "i1", "draft_id": "d1"}],
    )

    assert sweep_queue(db, now=NOW)["stranded_total"] == 0


def test_an_unflagged_expired_draft_is_not_stranded():
    """It took the SLA path and the user was told. Counting it would make the
    number mean "expired" rather than "nobody will ever hear about this"."""
    db = db_with([draft(status="expired", sla_due_at=ts(hours=48))])

    sweep_queue(db, now=NOW)

    assert sweep_queue(db, now=NOW)["stranded_total"] == 0
