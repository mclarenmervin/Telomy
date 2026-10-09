"""Turning a trend into something a clinician can sign.

`marker_trends` decides *whether* a human should look. This decides what they
are shown, and the two are separate because one is arithmetic over values and
the other is a sentence plus a routing decision.

Three properties matter more than the wording:

**A draft never sits in front of the escalation path.** A potassium of 7 goes to
`lab_escalations` immediately, deterministically, and independently of any
review state. If a critical value could also produce a draft, the queue would
be standing between a person and an emergency — so a critical latest value
produces no draft at all.

**The body states arithmetic, not meaning.** "HbA1c has risen 11.1% from 5.4%
to 6.0%" is a fact about two numbers. "Your HbA1c is high" is a clinical claim
sourced from a catalog no clinician has reviewed. The second is the clinician's
sentence to write, which is what `revised` exists for in the state machine.

**The same trend does not draft twice.** A nightly sweep would otherwise put the
same finding in the queue every night until somebody acted on it, and a queue
that grows while being worked is a queue nobody works.
"""

from datetime import date, timedelta

from app.agent.guardrails import CLINICIAN_QUEUE, apply_guardrails
from app.analytics.marker_trends import find_trends
from app.clinical.drafts import (
    DRAFT_KIND,
    create_drafts,
    draft_for_trend,
    trend_drafts,
)
from tests.fakes import FakeSupabase

TODAY = date(2026, 10, 10)
USER = "11111111-0000-4000-8000-000000000001"


def result(value, days_ago, *, marker="hba1c", unit="%", context="standard", **extra):
    row = {
        "biomarker_id": marker,
        "context": context,
        "result_type": "quantitative",
        "operator": "=",
        "value_canonical": value,
        "unit_canonical": unit,
        "collected_at": (TODAY - timedelta(days=days_ago)).isoformat(),
        "lab_name": "Test Labs",
    }
    row.update(extra)
    return row


def rising_hba1c():
    return [result(5.4, 240), result(5.7, 120), result(6.0, 10)]


def one_trend(rows=None):
    trends = find_trends(rows or rising_hba1c(), as_of=TODAY)
    assert trends, "the fixture must produce a trend for this test to mean anything"
    return trends[0]


# ── The sentence ─────────────────────────────────────────────────────────────

def test_the_body_states_the_arithmetic():
    draft = draft_for_trend(one_trend(), user_id=USER)

    assert "5.4%" in draft.body
    assert "6.0%" in draft.body
    assert "11.1%" in draft.body


def test_the_marker_is_named_the_way_a_lab_report_names_it():
    """F4 shipped "Rdw" and "Hs crp" to a real screen with every test green,
    because a biomarker_id was title-cased instead of being looked up. The
    catalog carries the printed name; this uses it."""
    draft = draft_for_trend(one_trend(), user_id=USER)

    assert "HbA1c" in draft.title
    assert "Hba1c" not in draft.title


def test_a_percentage_unit_does_not_take_a_space_and_others_do():
    """"5.4 %" is not how a report prints it, and "14.8g/dL" is not either."""
    hba1c = draft_for_trend(one_trend(), user_id=USER)
    assert "5.4%" in hba1c.body and "5.4 %" not in hba1c.body

    rows = [result(14.8, 240, marker="haemoglobin", unit="g/dL"),
            result(13.6, 120, marker="haemoglobin", unit="g/dL"),
            result(12.4, 10, marker="haemoglobin", unit="g/dL")]
    haemoglobin = draft_for_trend(one_trend(rows), user_id=USER)
    assert "12.4 g/dL" in haemoglobin.body


def test_the_body_makes_no_clinical_claim():
    """The catalog is an unreviewed v1 draft, so "high", "low", "abnormal" and
    "elevated" are claims we have no sign-off for. Note this is about the
    *agent's* text: the clinician may write any of those words when they revise
    it, and that is the point of the workflow."""
    draft = draft_for_trend(one_trend(), user_id=USER)

    for claim in ("high", "low", "abnormal", "elevated", "normal", "concerning",
                  "risk", "prediabet", "diabet"):
        assert claim not in draft.body.lower(), claim


def test_the_dates_are_the_collection_dates():
    draft = draft_for_trend(one_trend(), user_id=USER)

    assert "2026" in draft.body
    # The latest draw was 10 days before TODAY, not TODAY.
    assert (TODAY - timedelta(days=10)).strftime("%-d %B %Y") in draft.body


def test_a_falling_marker_is_described_as_falling():
    rows = [result(14.8, 240, marker="haemoglobin", unit="g/dL"),
            result(13.6, 120, marker="haemoglobin", unit="g/dL"),
            result(12.4, 10, marker="haemoglobin", unit="g/dL")]
    draft = draft_for_trend(one_trend(rows), user_id=USER)

    assert "fallen" in draft.body.lower()
    assert "risen" not in draft.body.lower()


# ── The evidence ─────────────────────────────────────────────────────────────

def test_every_point_travels_with_the_draft():
    """A clinician asked to put their registration number against this needs the
    series in front of them, not a summary. The console should not have to query
    anything to review a draft."""
    draft = draft_for_trend(one_trend(), user_id=USER)

    assert [e["value_canonical"] for e in draft.evidence] == [5.4, 5.7, 6.0]
    assert all(e["collected_at"] for e in draft.evidence)
    assert all(e["unit_canonical"] == "%" for e in draft.evidence)


def test_the_lab_is_named_in_the_evidence():
    """Two labs disagreeing by 0.3% is a plausible explanation for a trend, and
    a clinician cannot consider it if the draft does not say who ran each one."""
    draft = draft_for_trend(one_trend(), user_id=USER)

    assert all(e["lab_name"] == "Test Labs" for e in draft.evidence)


def test_the_evidence_is_json_safe():
    """It goes into a jsonb column. A `date` object would raise at insert time,
    on the nightly sweep, where nobody is watching."""
    import json

    json.dumps(draft_for_trend(one_trend(), user_id=USER).evidence)


# ── Safety: a draft never stands in front of an escalation ───────────────────

def test_a_critical_latest_value_produces_no_draft():
    """A haemoglobin of 4.1 escalates through lab_escalations today, not at the
    next appointment. Drafting it as well would put a review queue in front of
    an emergency, which is the one thing the plan says must never happen."""
    rows = [result(9.0, 240, marker="haemoglobin", unit="g/dL"),
            result(7.0, 120, marker="haemoglobin", unit="g/dL"),
            result(4.1, 10, marker="haemoglobin", unit="g/dL")]
    trend = one_trend(rows)

    assert trend.direction == "falling", "the fixture must trend for this to mean anything"
    assert draft_for_trend(trend, user_id=USER) is None


def test_a_non_critical_trend_in_the_same_marker_still_drafts():
    """The mirror image. Suppressing every haemoglobin trend because some
    haemoglobin values are critical would be the easy wrong fix."""
    rows = [result(14.8, 240, marker="haemoglobin", unit="g/dL"),
            result(13.6, 120, marker="haemoglobin", unit="g/dL"),
            result(12.4, 10, marker="haemoglobin", unit="g/dL")]

    assert draft_for_trend(one_trend(rows), user_id=USER) is not None


def test_a_critical_value_earlier_in_the_series_does_not_suppress_the_draft():
    """"Is this an emergency now" is a question about the latest value. A
    haemoglobin that was critical a year ago and has recovered is exactly the
    trend a clinician would want to see."""
    rows = [result(5.5, 240, marker="haemoglobin", unit="g/dL"),
            result(9.0, 120, marker="haemoglobin", unit="g/dL"),
            result(12.4, 10, marker="haemoglobin", unit="g/dL")]

    assert draft_for_trend(one_trend(rows), user_id=USER) is not None


# ── Routing flags ────────────────────────────────────────────────────────────

def test_a_trend_draft_carries_no_routing_flags():
    """Arithmetic about two numbers trips none of the guardrail rules, which is
    what makes a trend draft eligible for the SLA path: if the queue stalls, an
    observation-only version can still reach the user. A false positive here
    would strand it in the queue forever."""
    draft = draft_for_trend(one_trend(), user_id=USER)

    assert draft.routing_flags == []


def test_the_flags_are_whatever_the_clinician_profile_says_they_are():
    """Not recomputed here with a second set of rules. If the guardrail and the
    draft producer disagreed about what counts as medication content, a draft
    could reach a user unflagged carrying text the autonomous profile would
    have replaced."""
    draft = draft_for_trend(one_trend(), user_id=USER)
    _, flags = apply_guardrails(draft.body, {"metrics": {}}, profile=CLINICIAN_QUEUE)

    assert draft.routing_flags == flags


def test_the_body_is_never_replaced_by_the_safe_fallback():
    """The clinician_queue profile is what stops that. In the autonomous profile
    a flagged body becomes SAFE_FALLBACK, and a queue of safe fallbacks is a
    queue of drafts that say nothing."""
    from app.agent.guardrails import SAFE_FALLBACK

    assert draft_for_trend(one_trend(), user_id=USER).body != SAFE_FALLBACK


# ── Provenance and idempotency ───────────────────────────────────────────────

def test_the_draft_records_what_produced_it():
    draft = draft_for_trend(one_trend(), user_id=USER)

    assert draft.kind == DRAFT_KIND
    assert draft.model_version
    assert draft.user_id == USER


def test_the_dedupe_key_identifies_the_finding_not_the_run():
    """Keyed on the marker, the context and the latest draw. Two sweeps on
    different days see the same key for the same finding; a new panel changes
    the draw date and so becomes a new finding."""
    first = draft_for_trend(one_trend(), user_id=USER)
    again = draft_for_trend(one_trend(), user_id=USER)

    assert first.dedupe_key == again.dedupe_key
    assert "hba1c" in first.dedupe_key
    assert (TODAY - timedelta(days=10)).isoformat() in first.dedupe_key


def test_a_new_panel_is_a_new_finding():
    old = draft_for_trend(one_trend(), user_id=USER)
    newer = draft_for_trend(
        one_trend(rising_hba1c() + [result(6.3, 1)]), user_id=USER
    )

    assert old.dedupe_key != newer.dedupe_key


def test_fasting_and_post_prandial_do_not_share_a_key():
    """They are one biomarker_id and two measurements. Sharing a key would mean
    whichever drafted first silently suppressed the other."""
    fasting = [result(88, 240, marker="glucose_fasting", unit="mg/dL",
                      context="fasting"),
               result(96, 120, marker="glucose_fasting", unit="mg/dL",
                      context="fasting"),
               result(104, 10, marker="glucose_fasting", unit="mg/dL",
                      context="fasting")]
    post = [dict(r, context="post_prandial") for r in fasting]

    keys = {draft_for_trend(t, user_id=USER).dedupe_key
            for t in find_trends(fasting + post, as_of=TODAY)}

    assert len(keys) == 2


# ── Persisting ───────────────────────────────────────────────────────────────

def test_drafts_are_written_as_drafted():
    """The state machine refuses anything else on insert, so a producer that
    queued directly would fail at the database. Queuing is a separate decision."""
    db = FakeSupabase()
    create_drafts(db, USER, trend_drafts(rising_hba1c(), user_id=USER, as_of=TODAY))

    rows = db.tables["clinical_drafts"]
    assert len(rows) == 1
    assert rows[0]["status"] == "drafted"
    assert rows[0]["user_id"] == USER


def test_the_same_finding_is_not_drafted_twice():
    """The nightly sweep runs every night. Without this the queue grows by one
    row per night per finding until somebody acts on it."""
    db = FakeSupabase()
    candidates = trend_drafts(rising_hba1c(), user_id=USER, as_of=TODAY)

    created = create_drafts(db, USER, candidates)
    again = create_drafts(db, USER, candidates)

    assert len(created) == 1
    assert again == []
    assert len(db.tables["clinical_drafts"]) == 1


def test_a_draft_already_rejected_is_not_recreated():
    """A clinician who said no must not be asked again tomorrow. The dedupe key
    does not care what state the existing draft reached."""
    db = FakeSupabase()
    candidates = trend_drafts(rising_hba1c(), user_id=USER, as_of=TODAY)
    create_drafts(db, USER, candidates)
    db.tables["clinical_drafts"][0]["status"] = "rejected"

    assert create_drafts(db, USER, candidates) == []


def test_another_users_identical_finding_is_a_separate_draft():
    """The dedupe key is scoped per user. Two people whose HbA1c both rose to
    6.0 on the same day is unremarkable, and suppressing the second would be a
    cross-tenant bug of the quietest possible kind."""
    db = FakeSupabase()
    other = "22222222-0000-4000-8000-000000000002"
    create_drafts(db, USER, trend_drafts(rising_hba1c(), user_id=USER, as_of=TODAY))
    create_drafts(db, other, trend_drafts(rising_hba1c(), user_id=other, as_of=TODAY))

    assert len(db.tables["clinical_drafts"]) == 2


def test_the_clinic_is_recorded_when_there_is_one():
    db = FakeSupabase()
    clinic = "33333333-0000-4000-8000-000000000003"
    create_drafts(
        db, USER, trend_drafts(rising_hba1c(), user_id=USER, as_of=TODAY),
        clinic_id=clinic,
    )

    assert db.tables["clinical_drafts"][0]["clinic_id"] == clinic


def test_no_clinic_means_the_network_pool():
    """Null clinic_id is the Bonphul pool, which any clinician in good standing
    may claim. A user not enrolled with a clinic still gets reviewed."""
    db = FakeSupabase()
    create_drafts(db, USER, trend_drafts(rising_hba1c(), user_id=USER, as_of=TODAY))

    assert db.tables["clinical_drafts"][0]["clinic_id"] is None


def test_an_sla_deadline_is_set_so_the_sweep_has_something_to_find():
    db = FakeSupabase()
    create_drafts(db, USER, trend_drafts(rising_hba1c(), user_id=USER, as_of=TODAY))

    assert db.tables["clinical_drafts"][0]["sla_due_at"] is not None


def test_nothing_to_draft_writes_nothing():
    db = FakeSupabase()

    assert create_drafts(db, USER, []) == []
    assert db.tables.get("clinical_drafts", []) == []


def test_no_trend_produces_no_candidates():
    assert trend_drafts([result(5.4, 240), result(5.5, 10)],
                        user_id=USER, as_of=TODAY) == []
