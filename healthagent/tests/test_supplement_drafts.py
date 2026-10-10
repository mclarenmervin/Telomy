"""Turning a deficiency into something a clinician must sign.

The asymmetry this phase exists to create, tested from both sides. F5 shipped
observation-only drafts: statements of arithmetic that carry no routing flags
and are therefore eligible for the SLA escape hatch, so a stalled queue still
lets them reach the user. A supplement draft is the opposite by construction --
it carries a flag, and the database refuses to deliver a flagged draft without
a signature.

The flag comes from the guardrail rather than from this producer, which is the
part worth being careful about. A producer that set `routing_flags=['supplement']`
by hand would drift from what the autonomous profile actually blocks, and a
draft could then reach a user unflagged carrying text the other profile would
have replaced. So the body is built, run through `apply_guardrails` in the
clinician profile, and whatever comes back is what the draft carries -- and a
supplement draft the guardrail did not flag is refused outright rather than
written unflagged.
"""

from datetime import date, timedelta

import pytest

from app.agent.guardrails import CLINICIAN_QUEUE, apply_guardrails, gate_delivery
from app.analytics import catalog, supplement_rules
from app.analytics.reference_ranges import RangeResolver
from app.analytics.subject import Subject
from app.analytics.supplements import MODEL_VERSION
from app.clinical.supplement_drafts import (
    DRAFT_KIND,
    supplement_drafts,
)
from tests.fakes import FakeSupabase

TODAY = date(2026, 10, 10)
USER = "11111111-1111-4111-8111-111111111111"


@pytest.fixture(autouse=True)
def _clear_caches():
    _clear()
    yield
    _clear()


def _clear():
    for cache in (
        catalog.load_catalog,
        catalog.review_status,
        catalog.alias_index,
        supplement_rules.load_rules,
        supplement_rules.review_status,
        supplement_rules.rules_for,
    ):
        cache.cache_clear()


def result(value, days_ago, *, marker="vitamin_d_25oh", unit="ng/mL", **extra):
    row = {
        "biomarker_id": marker,
        "context": "standard",
        "result_type": "quantitative",
        "operator": "=",
        "value_canonical": value,
        "unit_canonical": unit,
        "value_text": None,
        "collected_at": (TODAY - timedelta(days=days_ago)).isoformat(),
        "lab_name": "Thyrocare",
    }
    row.update(extra)
    return row


def sign_off(monkeypatch, tmp_path, *, rules=("vitamin_d_repletion",),
             markers=("vitamin_d_25oh",), recommendation=None):
    """Sign the rule file and the catalog, optionally rewriting a recommendation.

    `recommendation` is how the guardrail-refusal test puts a bland sentence in
    front of the producer without mocking the guardrail: the rule file is
    reviewed content, and a reviewed sentence that reads as an observation
    rather than a recommendation is a real thing somebody could commit.
    """
    import yaml

    raw = yaml.safe_load(supplement_rules.RULES_PATH.read_text())
    if recommendation is not None:
        for entry in raw["rules"]:
            if entry["id"] in rules:
                entry["recommendation"] = recommendation
    path = tmp_path / "supplements.yaml"
    path.write_text(yaml.safe_dump(raw, sort_keys=False))
    monkeypatch.setattr(supplement_rules, "RULES_PATH", path)
    _clear()
    raw["clinical_review"]["rules"] = [
        {
            "id": rule_id,
            "reviewer": "Dr A. Example, MBBS MD, reg. 12345",
            "reviewed_at": "2026-10-10",
            "content_sha256": supplement_rules.rule_fingerprint(rule_id),
        }
        for rule_id in rules
    ]
    path.write_text(yaml.safe_dump(raw, sort_keys=False))
    _clear()

    catalog_raw = yaml.safe_load(catalog.CATALOG_PATH.read_text())
    catalog_path = tmp_path / "biomarkers.yaml"
    catalog_path.write_text(yaml.safe_dump(catalog_raw, sort_keys=False))
    monkeypatch.setattr(catalog, "CATALOG_PATH", catalog_path)
    _clear()
    catalog_raw["clinical_review"]["markers"] = [
        {
            "id": marker_id,
            "reviewer": "Dr A. Example, MBBS MD, reg. 12345",
            "reviewed_at": "2026-10-10",
            "content_sha256": catalog.marker_fingerprint(marker_id),
        }
        for marker_id in markers
    ]
    catalog_path.write_text(yaml.safe_dump(catalog_raw, sort_keys=False))
    _clear()


def drafts(rows, *, medications=(), sex=None, subject=None):
    return supplement_drafts(
        rows,
        user_id=USER,
        as_of=TODAY,
        resolve=lambda marker: RangeResolver().resolve(marker, USER, sex),
        subject=subject if subject is not None else Subject(age_years=41.0, sex=sex),
        medications=medications,
    )


def one(rows, **kwargs):
    made = drafts(rows, **kwargs)
    assert len(made) == 1, made
    return made[0]


LOW_D = [result(14, 10)]


# ── The draft ────────────────────────────────────────────────────────────────

def test_a_deficiency_becomes_a_supplement_draft(monkeypatch, tmp_path):
    sign_off(monkeypatch, tmp_path)

    candidate = one(LOW_D)

    assert candidate.kind == DRAFT_KIND == "supplement"
    assert candidate.user_id == USER
    assert candidate.model_version == MODEL_VERSION
    assert candidate.source_kind == "biomarker_deficiency"


def test_nothing_is_drafted_while_the_rules_are_unsigned():
    """The shipped state, stated here as well as in the rule tests: this is the
    producer that would otherwise be filling a queue with recommendations no
    clinician has agreed to."""
    assert drafts(LOW_D) == []


def test_the_body_states_the_value_the_date_and_the_range(monkeypatch, tmp_path):
    """A clinician asked to sign a recommendation needs the measurement it rests
    on in the sentence, not only in an evidence panel they may not open."""
    sign_off(monkeypatch, tmp_path)

    body = one(LOW_D).body

    assert "Vitamin D (25-OH)" in body
    assert "14 ng/mL" in body
    assert "30 September 2026" in body
    assert "30" in body and "100" in body


def test_the_body_carries_the_reviewed_recommendation(monkeypatch, tmp_path):
    """Verbatim from the rule file. The sentence is reviewed content, so the
    producer fills in numbers and does not paraphrase the medical wording."""
    sign_off(monkeypatch, tmp_path)
    recommendation = supplement_rules.get("vitamin_d_repletion").recommendation

    assert recommendation in one(LOW_D).body


def test_the_title_names_the_marker_not_its_identifier(monkeypatch, tmp_path):
    """F4 shipped "Rdw" and "Hs crp" to a real screen with every test green, so
    the printed name is asserted rather than assumed."""
    sign_off(monkeypatch, tmp_path, rules=("magnesium_repletion",),
             markers=("magnesium",))

    title = one([result(1.4, 10, marker="magnesium", unit="mg/dL")]).title

    assert "Magnesium" in title
    assert "magnesium_repletion" not in title


# ── The flag, and where it comes from ────────────────────────────────────────

def test_a_supplement_draft_always_carries_a_routing_flag(monkeypatch, tmp_path):
    """The whole asymmetry. Without a flag the SLA sweep could deliver a
    recommendation to a user that no clinician ever read."""
    sign_off(monkeypatch, tmp_path)

    assert one(LOW_D).routing_flags


def test_the_flag_is_the_one_the_guardrail_returns(monkeypatch, tmp_path):
    """Not a label this producer chose. If the two disagreed about what counts
    as medication content, a draft could reach a user unflagged carrying text
    the autonomous profile would have replaced."""
    sign_off(monkeypatch, tmp_path)
    candidate = one(LOW_D)

    _, flags = apply_guardrails(candidate.body, {"metrics": {}},
                                profile=CLINICIAN_QUEUE)

    assert candidate.routing_flags == flags


def test_a_draft_the_guardrail_would_not_flag_is_refused(monkeypatch, tmp_path):
    """The invariant stated as a refusal rather than as a hand-set flag.

    If a reviewed recommendation ever reads as a bland observation, the
    guardrail returns no flags and the draft would be SLA-deliverable -- a
    supplement recommendation reaching a user unreviewed. Refusing to create it
    is the safe failure: a clinician is not asked, and nobody is told anything.
    """
    sign_off(monkeypatch, tmp_path,
             recommendation="This level has been noted in the record.")

    assert drafts(LOW_D) == []


def test_the_refusal_is_logged_loudly(monkeypatch, tmp_path, caplog):
    sign_off(monkeypatch, tmp_path,
             recommendation="This level has been noted in the record.")

    with caplog.at_level("ERROR"):
        drafts(LOW_D)

    assert "vitamin_d_repletion" in caplog.text


# ── Medications ──────────────────────────────────────────────────────────────

def test_an_interaction_is_named_in_the_body(monkeypatch, tmp_path):
    """The plan's own example of what this phase is for. A clinician must not
    have to notice the interaction themselves."""
    sign_off(monkeypatch, tmp_path, rules=("magnesium_repletion",),
             markers=("magnesium",))
    medications = [{"title": "Spironolactone 25mg", "notes": "once daily"}]

    body = one([result(1.4, 10, marker="magnesium", unit="mg/dL")],
               medications=medications).body

    assert "Spironolactone 25mg" in body
    assert "hypermagnesaemia" in body


def test_an_interaction_appears_in_the_evidence(monkeypatch, tmp_path):
    sign_off(monkeypatch, tmp_path, rules=("b12_repletion",),
             markers=("vitamin_b12",))
    medications = [{"title": "Tab. Metformin 500mg", "notes": "twice daily"}]

    candidate = one([result(150, 10, marker="vitamin_b12", unit="pg/mL")],
                    medications=medications)
    interactions = [e for e in candidate.evidence if e["kind"] == "interaction"]

    assert [e["recorded_as"] for e in interactions] == ["Tab. Metformin 500mg"]
    assert "metformin" == interactions[0]["medication"]


def test_no_interaction_leaves_the_body_as_the_recommendation(monkeypatch, tmp_path):
    sign_off(monkeypatch, tmp_path)

    body = one(LOW_D, medications=[{"title": "Cetirizine 10mg"}]).body

    assert "Also recorded" not in body


# ── Evidence ─────────────────────────────────────────────────────────────────

def test_the_measurement_is_in_the_evidence_in_the_shape_the_app_reads(
    monkeypatch, tmp_path
):
    """The same keys F5's trend evidence uses, because the phone parses one
    shape. An entry the app cannot read renders as a blank row, which is the
    class of bug F4 and F5 both shipped to a screen."""
    sign_off(monkeypatch, tmp_path)

    measurement = next(
        e for e in one(LOW_D).evidence if e["kind"] == "measurement"
    )

    assert measurement["biomarker_id"] == "vitamin_d_25oh"
    assert measurement["value_canonical"] == 14
    assert measurement["unit_canonical"] == "ng/mL"
    assert measurement["collected_at"] == "2026-09-30"
    assert measurement["lab_name"] == "Thyrocare"


def test_the_range_and_its_version_are_in_the_evidence(monkeypatch, tmp_path):
    """A recommendation rests on a range, and a range changed tomorrow must not
    retroactively rewrite what this draft claimed."""
    sign_off(monkeypatch, tmp_path)

    entry = next(e for e in one(LOW_D).evidence if e["kind"] == "reference_range")

    assert entry["standard_low"] == 30
    assert entry["standard_high"] == 100
    assert entry["ranges_version"]
    assert entry["citation"]


def test_the_rule_and_who_signed_it_are_in_the_evidence(monkeypatch, tmp_path):
    """Two signatures stand behind a delivered supplement insight: the clinician
    who signed this draft, and the clinician who signed the rule it applied.
    The second one is invisible unless the draft carries it."""
    sign_off(monkeypatch, tmp_path)

    entry = next(e for e in one(LOW_D).evidence if e["kind"] == "rule")

    assert entry["rule_id"] == "vitamin_d_repletion"
    assert entry["supplement"] == "Vitamin D3 (cholecalciferol)"
    assert "Dr A. Example" in entry["reviewer"]
    assert entry["citation"]


def test_every_evidence_entry_is_json_safe(monkeypatch, tmp_path):
    """It lands in a jsonb column on an unattended sweep. A date object raises
    at insert time where nobody is watching -- the F5 note that is already a
    comment in `drafts.py`."""
    import json

    sign_off(monkeypatch, tmp_path)

    json.dumps(one(LOW_D).evidence)


# ── Idempotency ──────────────────────────────────────────────────────────────

def test_the_same_deficiency_has_the_same_key(monkeypatch, tmp_path):
    """The nightly sweep runs every night. Without this the queue grows by one
    row per night per finding until somebody acts on it."""
    sign_off(monkeypatch, tmp_path)

    assert one(LOW_D).dedupe_key == one(LOW_D).dedupe_key
    assert "vitamin_d_repletion" in one(LOW_D).dedupe_key


def test_a_new_panel_is_a_new_finding(monkeypatch, tmp_path):
    """Still deficient on a fresh draw is a new finding: the clinician's view of
    the old number has already been given, and a new measurement deserves one."""
    sign_off(monkeypatch, tmp_path)

    assert one(LOW_D).dedupe_key != one([result(16, 2)]).dedupe_key


def test_two_markers_do_not_share_a_key(monkeypatch, tmp_path):
    sign_off(
        monkeypatch,
        tmp_path,
        rules=("vitamin_d_repletion", "b12_repletion"),
        markers=("vitamin_d_25oh", "vitamin_b12"),
    )

    keys = {
        c.dedupe_key
        for c in drafts(LOW_D + [result(150, 10, marker="vitamin_b12", unit="pg/mL")])
    }

    assert len(keys) == 2


# ── The asymmetry, from both sides ───────────────────────────────────────────

def test_a_supplement_draft_cannot_be_delivered_unreviewed(monkeypatch, tmp_path):
    """The Python half of the gate, which exists so the sweep does not fire
    inserts the database is certain to refuse. The enforcement is the trigger in
    013, tested from SQL."""
    sign_off(monkeypatch, tmp_path)
    candidate = one(LOW_D)
    row = candidate.row(clinic_id=None, sla_due_at="2026-10-13T00:00:00Z")
    row["id"] = "d1"
    row["status"] = "expired"  # the SLA sweep has given up on it

    decision = gate_delivery(row, None)

    assert decision.deliverable is False
    assert "routing flags" in decision.reason


def test_a_trend_draft_in_the_same_state_can_be(monkeypatch, tmp_path):
    """The other side of the asymmetry, so that a change which widened the gate
    would fail here rather than silently making the two cases the same. An
    observation that nobody reviewed still reaches the user; a recommendation
    never does."""
    from app.clinical.drafts import trend_drafts

    sign_off(monkeypatch, tmp_path)
    rising = [
        result(5.4, 240, marker="hba1c", unit="%"),
        result(5.7, 120, marker="hba1c", unit="%"),
        result(6.0, 10, marker="hba1c", unit="%"),
    ]
    candidate = trend_drafts(rising, user_id=USER, as_of=TODAY)[0]
    row = candidate.row(clinic_id=None, sla_due_at="2026-10-13T00:00:00Z")
    row["id"] = "d2"
    row["status"] = "expired"

    assert candidate.routing_flags == []
    assert gate_delivery(row, None).deliverable is True


def test_supplement_drafts_are_written_as_drafted(monkeypatch, tmp_path):
    """Through the same `create_drafts` the trend producer uses: one writer, one
    dedupe check, one place that knows about the state machine."""
    from app.clinical.drafts import create_drafts

    sign_off(monkeypatch, tmp_path)
    db = FakeSupabase()

    create_drafts(db, USER, drafts(LOW_D))

    rows = db.tables["clinical_drafts"]
    assert len(rows) == 1
    assert rows[0]["status"] == "drafted"
    assert rows[0]["kind"] == "supplement"
    assert rows[0]["routing_flags"]


# ── Every shipped rule can actually produce a draft ──────────────────────────

DEFICIENT = {
    "vitamin_d_repletion": (result(14, 10, marker="vitamin_d_25oh", unit="ng/mL"),
                            "vitamin_d_25oh", None),
    "b12_repletion": (result(150, 10, marker="vitamin_b12", unit="pg/mL"),
                      "vitamin_b12", None),
    "iron_repletion": (result(10, 10, marker="ferritin", unit="ng/mL"),
                       "ferritin", "female"),
    "magnesium_repletion": (result(1.4, 10, marker="magnesium", unit="mg/dL"),
                            "magnesium", None),
}


@pytest.mark.parametrize("rule_id", sorted(DEFICIENT))
def test_each_shipped_rule_drafts_once_signed(monkeypatch, tmp_path, rule_id):
    """A rule whose recommendation the guardrail does not flag would be refused
    and would silently never draft -- the file would look fine and the queue
    would stay empty. This is the test that says the phase works the day
    somebody signs it.
    """
    row, marker, sex = DEFICIENT[rule_id]
    sign_off(monkeypatch, tmp_path, rules=(rule_id,), markers=(marker,))

    candidate = one([row], sex=sex)

    assert candidate.routing_flags
    assert supplement_rules.get(rule_id).recommendation in candidate.body


def test_every_rule_in_the_file_is_covered_by_that_test():
    """A rule added to the file without a case here would be untested, and the
    way it fails is that it never drafts."""
    assert set(DEFICIENT) == set(supplement_rules.load_rules()[1])


def test_a_subject_who_must_not_be_recommended_to_gets_no_draft(monkeypatch, tmp_path):
    """The refusal belongs to `find_deficiencies` and is tested there. This is
    the pass-through: a producer that built its own subject, or forgot to pass
    one, would be a second copy of the rule."""
    sign_off(monkeypatch, tmp_path)
    pregnant = Subject(age_years=31.0, sex="female", refusals=("pregnancy",))

    assert drafts(LOW_D, subject=pregnant) == []
