"""Which measured deficiencies justify a supplement recommendation.

The deterministic half of F6's producer, and the same split F5 used: this
decides *whether* a human should be asked, `clinical/supplement_drafts.py`
decides what they are shown. Per CLAUDE.md the decision is a testable rule in
ordinary Python; nothing in this module writes a sentence of its own, and the
one sentence it carries comes from the reviewed rule file.

Four gates, and every one of them is the difference between a recommendation
and a liability:

1. **Both signatures.** The rule has to be signed off, and so does the marker's
   reference range -- the draft states the range the value fell below, and that
   is a separate claim by a separate signature.
2. **Below the standard range, not merely below optimal.** Repletion of a
   deficiency, never optimisation.
3. **Never in front of an escalation.** A critical value is already an
   escalation, written independently of review state. A supplement suggestion
   waiting in a queue must not be the response to it.
4. **Medications are read, and named.** They never suppress the rule -- they
   are exactly what makes it a human's decision.
"""

from datetime import date, timedelta

import pytest

from app.analytics import catalog, supplement_rules
from app.analytics.reference_ranges import RangeResolver
from app.analytics.subject import Subject
from app.analytics.supplements import MODEL_VERSION, find_deficiencies

TODAY = date(2026, 10, 10)


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


def result(value, days_ago, *, marker="vitamin_d_25oh", unit="ng/mL",
           context="standard", **extra):
    row = {
        "biomarker_id": marker,
        "context": context,
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
             markers=("vitamin_d_25oh",)):
    """Sign the rule file and the biomarker catalog, as a clinician would.

    Both are needed, so every test that expects a finding has to say so. The
    shipped files are unsigned and that is what the first test asserts.
    """
    _sign_rules(monkeypatch, tmp_path, rules)
    _sign_markers(monkeypatch, tmp_path, markers)
    _clear()


def _sign_rules(monkeypatch, tmp_path, rule_ids):
    import yaml

    raw = yaml.safe_load(supplement_rules.RULES_PATH.read_text())
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
        for rule_id in rule_ids
    ]
    path.write_text(yaml.safe_dump(raw, sort_keys=False))
    _clear()


def _sign_markers(monkeypatch, tmp_path, marker_ids):
    import yaml

    raw = yaml.safe_load(catalog.CATALOG_PATH.read_text())
    path = tmp_path / "biomarkers.yaml"
    path.write_text(yaml.safe_dump(raw, sort_keys=False))
    monkeypatch.setattr(catalog, "CATALOG_PATH", path)
    _clear()

    raw["clinical_review"]["markers"] = [
        {
            "id": marker_id,
            "reviewer": "Dr A. Example, MBBS MD, reg. 12345",
            "reviewed_at": "2026-10-10",
            "content_sha256": catalog.marker_fingerprint(marker_id),
        }
        for marker_id in marker_ids
    ]
    path.write_text(yaml.safe_dump(raw, sort_keys=False))
    _clear()


def find(rows, *, medications=(), sex=None, subject=None):
    return find_deficiencies(
        rows,
        as_of=TODAY,
        resolve=lambda marker: RangeResolver().resolve(marker, "u1", sex),
        medications=medications,
        subject=subject if subject is not None else Subject(age_years=41.0, sex=sex),
    )


# ── Nothing is signed, so nothing fires ──────────────────────────────────────

def test_an_unsigned_rule_produces_nothing():
    """The shipped state. A deficiency is found and deliberately not acted on,
    because no clinician has agreed what to do about one."""
    assert find([result(14, 10)]) == []


def test_a_signed_rule_on_an_unsigned_marker_produces_nothing(monkeypatch, tmp_path):
    """Both signatures, not either. The draft would state the range the value
    fell below, and nobody has agreed that range is right."""
    _sign_rules(monkeypatch, tmp_path, ("vitamin_d_repletion",))

    assert find([result(14, 10)]) == []


def test_a_signed_marker_with_an_unsigned_rule_produces_nothing(monkeypatch, tmp_path):
    """The other way round, and the more tempting mistake: the range is signed,
    so the number can be graded -- but what to do about it is a separate claim
    that nobody has made."""
    _sign_markers(monkeypatch, tmp_path, ("vitamin_d_25oh",))

    assert find([result(14, 10)]) == []


# ── The rule itself ──────────────────────────────────────────────────────────

def test_a_value_below_the_standard_range_is_a_finding(monkeypatch, tmp_path):
    sign_off(monkeypatch, tmp_path)

    findings = find([result(14, 10)])

    assert [f.rule.id for f in findings] == ["vitamin_d_repletion"]
    assert findings[0].value.value_canonical == 14
    assert findings[0].standard.low == 30
    assert findings[0].model_version == MODEL_VERSION


def test_a_value_inside_the_standard_range_is_not_a_finding(monkeypatch, tmp_path):
    """35 ng/mL is inside the standard range and below optimal. Recommending a
    supplement for it is optimisation, which is not what this ships."""
    sign_off(monkeypatch, tmp_path)

    assert find([result(35, 10)]) == []


def test_a_value_above_the_standard_range_is_not_a_finding(monkeypatch, tmp_path):
    """Abnormal in the other direction. A vitamin D of 120 is not a reason to
    take more of it, and `abnormal` alone would have said it was."""
    sign_off(monkeypatch, tmp_path)

    assert find([result(120, 10)]) == []


def test_a_critical_value_is_not_a_finding(monkeypatch, tmp_path):
    """The escalation path owns this value. A supplement suggestion sitting in a
    review queue must never be the system's response to a critical result."""
    sign_off(monkeypatch, tmp_path)

    assert find([result(3, 10)]) == []


def test_only_the_latest_result_decides(monkeypatch, tmp_path):
    """A deficiency is a statement about now. An old low that has since been
    corrected is not a reason to recommend anything."""
    sign_off(monkeypatch, tmp_path)

    assert find([result(14, 200), result(48, 10)]) == []


def test_a_deficiency_in_history_produces_nothing(monkeypatch, tmp_path):
    """The plan's backfill rule. Five years of old reports uploaded in one
    sitting must not produce five years of recommendations."""
    sign_off(monkeypatch, tmp_path)

    assert find([result(14, 400)]) == []


def test_a_censored_result_produces_nothing(monkeypatch, tmp_path):
    """`<10` is not 10. The lab could not measure past its bound, so the true
    value is unknown and cannot be the basis of a recommendation."""
    sign_off(monkeypatch, tmp_path)

    assert find([result(10, 10, operator="<")]) == []


def test_an_undated_result_produces_nothing(monkeypatch, tmp_path):
    sign_off(monkeypatch, tmp_path)

    assert find([result(14, 10, collected_at=None)]) == []


def test_a_sex_specific_marker_with_an_unknown_sex_produces_nothing(
    monkeypatch, tmp_path
):
    """Ferritin's standard range differs by sex, so there is no range to be
    below. Picking one would grade a woman against a man's threshold."""
    sign_off(monkeypatch, tmp_path, rules=("iron_repletion",), markers=("ferritin",))
    low = [result(10, 10, marker="ferritin", unit="ng/mL")]

    assert find(low) == []
    assert [f.rule.id for f in find(low, sex="female")] == ["iron_repletion"]


def test_findings_come_back_in_a_stable_order(monkeypatch, tmp_path):
    sign_off(
        monkeypatch,
        tmp_path,
        rules=("vitamin_d_repletion", "b12_repletion", "magnesium_repletion"),
        markers=("vitamin_d_25oh", "vitamin_b12", "magnesium"),
    )
    rows = [
        result(14, 10),
        result(150, 10, marker="vitamin_b12", unit="pg/mL"),
        result(1.4, 10, marker="magnesium", unit="mg/dL"),
    ]

    assert [f.rule.id for f in find(rows)] == [
        "b12_repletion",
        "magnesium_repletion",
        "vitamin_d_repletion",
    ]
    assert [f.rule.id for f in find(list(reversed(rows)))] == [
        "b12_repletion",
        "magnesium_repletion",
        "vitamin_d_repletion",
    ]


# ── Medications feed the interpretation ──────────────────────────────────────

def test_an_interacting_medication_is_named_on_the_finding(monkeypatch, tmp_path):
    """The plan requires medications to feed interpretation and not only
    guardrails. A B12 low on metformin may be explained by the drug, and the
    finding has to carry that rather than leaving it to be noticed."""
    sign_off(monkeypatch, tmp_path, rules=("b12_repletion",), markers=("vitamin_b12",))
    medications = [{"title": "Tab. Metformin 500mg", "notes": "twice daily"}]

    finding = find([result(150, 10, marker="vitamin_b12", unit="pg/mL")],
                   medications=medications)[0]

    assert [i.medication for i in finding.interactions] == ["metformin"]
    assert "lowers B12 absorption" in finding.interactions[0].note
    assert finding.interactions[0].recorded_as == "Tab. Metformin 500mg"


def test_an_interacting_medication_does_not_suppress_the_finding(monkeypatch, tmp_path):
    """It routes rather than silences. Suppressing it would mean the person most
    likely to need the conversation is the one who never gets it."""
    sign_off(monkeypatch, tmp_path, rules=("magnesium_repletion",),
             markers=("magnesium",))
    medications = [{"title": "Spironolactone 25mg", "notes": None}]

    findings = find([result(1.4, 10, marker="magnesium", unit="mg/dL")],
                    medications=medications)

    assert len(findings) == 1
    assert findings[0].interactions


def test_an_unrelated_medication_is_not_named(monkeypatch, tmp_path):
    sign_off(monkeypatch, tmp_path)
    medications = [{"title": "Cetirizine 10mg", "notes": "at night"}]

    finding = find([result(14, 10)], medications=medications)[0]

    assert finding.interactions == ()


def test_a_medication_is_read_from_the_notes_too(monkeypatch, tmp_path):
    """`medications` rows are free text a person typed, and the drug name is as
    likely to be in the note as in the title."""
    sign_off(monkeypatch, tmp_path, rules=("b12_repletion",), markers=("vitamin_b12",))
    medications = [{"title": "Diabetes", "notes": "metformin 1g daily"}]

    finding = find([result(150, 10, marker="vitamin_b12", unit="pg/mL")],
                   medications=medications)[0]

    assert [i.medication for i in finding.interactions] == ["metformin"]


def test_no_medications_is_not_an_error(monkeypatch, tmp_path):
    sign_off(monkeypatch, tmp_path)

    assert find([result(14, 10)], medications=None)[0].interactions == ()


# ── Who the recommendation is for ────────────────────────────────────────────
#
# The plan names three cases where a score must be refused rather than produced
# wrongly, and all three apply at least as strongly to a recommendation.
# Pregnancy shifts reference ranges substantially and changes what should be
# taken; adult ranges do not apply to a minor; and an unknown age means the
# minimum cannot be enforced at all.
#
# `Subject.scorable` is already exactly this question -- a known adult age and
# no refusals -- so it is asked rather than re-derived, for the same reason the
# review gate is asked through `grade_for_display`.

ADULT = Subject(age_years=41.0, sex=None)


def test_a_pregnant_subject_produces_nothing(monkeypatch, tmp_path):
    sign_off(monkeypatch, tmp_path)
    pregnant = Subject(age_years=31.0, sex="female", refusals=("pregnancy",))

    assert find([result(14, 10)], subject=pregnant) == []


def test_a_minor_produces_nothing(monkeypatch, tmp_path):
    """Adult ranges do not apply to a child, and a paediatric rule is separate
    medical content rather than a default."""
    sign_off(monkeypatch, tmp_path)
    minor = Subject(age_years=14.0, sex=None, refusals=("under_minimum_age",))

    assert find([result(14, 10)], subject=minor) == []


def test_an_unknown_age_produces_nothing(monkeypatch, tmp_path):
    """The minimum age cannot be enforced against an age we do not hold.
    Refusing costs a recommendation; proceeding risks recommending iron to a
    fourteen-year-old."""
    sign_off(monkeypatch, tmp_path)
    unknown = Subject(age_years=None, sex=None, refusals=("date_of_birth",))

    assert find([result(14, 10)], subject=unknown) == []


def test_an_adult_with_no_refusals_still_produces_one(monkeypatch, tmp_path):
    sign_off(monkeypatch, tmp_path)

    assert len(find([result(14, 10)], subject=ADULT)) == 1
