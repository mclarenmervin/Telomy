"""A critical value cannot wait in a queue.

If an uploaded panel contains a life-threatening result, the escalation fires
immediately and deterministically — before the user has confirmed anything,
while the catalog is still clinically unreviewed, and independent of any review
state. The clinician queue is for recommendations, never for emergencies.

The wording is the part that needs care. Whoop Advanced Labs and Function
Health both have a clinician *telephone* the member for a critical result. We
cannot do that until F5, so this says the one true thing we can say — this
number is far outside the expected range, have it looked at — and makes no
clinical claim, because the ranges it fired on have not been reviewed yet.
"""

from app.extraction.escalation import critical_findings
from app.extraction.ingest import ExtractedResult


def result(biomarker_id, value, operator="=", unit="g/dL", context="standard"):
    return ExtractedResult(
        biomarker_id=biomarker_id, context=context, result_type="quantitative",
        operator=operator, raw_value=str(value), raw_unit=unit,
        value_canonical=value, value_text=None, unit_canonical=unit,
        page=0, bbox={"x0": 1, "x1": 2, "top": 1, "bottom": 2},
        confidence=1.0, catalog_version="global.v1",
    )


# ── What fires ───────────────────────────────────────────────────────────────

def test_a_critical_value_produces_a_finding():
    """Haemoglobin's critical floor is 6.0 g/dL."""
    findings = critical_findings([result("haemoglobin", 4.1)])

    assert len(findings) == 1
    assert findings[0].biomarker_id == "haemoglobin"


def test_a_normal_value_produces_nothing():
    """False escalation is not harmless: a product that cries emergency at a
    normal haemoglobin trains people to ignore it."""
    assert critical_findings([result("haemoglobin", 14.0)]) == ()


def test_a_merely_abnormal_value_does_not_escalate():
    """11.0 is below the standard range and nowhere near the critical floor.
    That is a conversation with a doctor, not an emergency."""
    assert critical_findings([result("haemoglobin", 11.0)]) == ()


def test_a_value_above_the_critical_ceiling_escalates():
    assert len(critical_findings([result("haemoglobin", 23.0)])) == 1


def test_a_censored_value_past_a_critical_bound_still_escalates():
    """`>500` on a marker whose critical ceiling is 400 is unknown in magnitude
    but not in direction. Excluded from biological age, never from safety."""
    findings = critical_findings([
        result("glucose_fasting", 500.0, operator=">", unit="mg/dL")
    ])

    assert len(findings) == 1


def test_escalation_does_not_need_the_persons_sex():
    """Haemoglobin's standard range is sex-specific and its critical bounds are
    not. Routing this through the range resolver would mean a haemoglobin of 4.1
    escalates nothing for every user whose sex we do not hold."""
    assert len(critical_findings([result("haemoglobin", 4.1)])) == 1


def test_several_critical_values_each_produce_a_finding():
    findings = critical_findings([
        result("haemoglobin", 4.1),
        result("glucose_fasting", 500.0, unit="mg/dL"),
        result("ferritin", 100.0, unit="ng/mL"),
    ])

    assert {f.biomarker_id for f in findings} == {"haemoglobin", "glucose_fasting"}


# ── What it says ─────────────────────────────────────────────────────────────

def test_the_message_names_the_marker_and_the_value_as_printed():
    message = critical_findings([result("haemoglobin", 4.1)])[0].message

    assert "Haemoglobin" in message
    assert "4.1" in message
    assert "g/dL" in message


def test_the_message_makes_no_clinical_claim():
    """The ranges this fired on have not been reviewed by a clinician. Naming a
    condition would be a medical claim sourced from unreviewed content."""
    message = critical_findings([result("haemoglobin", 4.1)])[0].message.lower()

    for claim in ("anaemia", "anemia", "diagnos", "you have", "severe", "disease"):
        assert claim not in message


def test_the_message_directs_the_person_to_a_doctor():
    message = critical_findings([result("haemoglobin", 4.1)])[0].message.lower()

    assert "doctor" in message or "medical" in message


# ── Not gated on anything ────────────────────────────────────────────────────

def test_escalation_is_not_gated_on_clinical_review():
    """The catalog ships unreviewed, and grading is suppressed because of it.
    Escalation is deliberately exempt: a critical value cannot wait for a review
    meeting, and a bound we are unsure of is still a better reason to escalate
    than silence is."""
    from app.analytics import catalog

    assert catalog.review_status().reviewed is False
    assert len(critical_findings([result("haemoglobin", 4.1)])) == 1


def test_a_marker_we_do_not_carry_never_escalates():
    assert critical_findings([result("midichlorian_count", 99999.0)]) == ()


def test_finding_order_is_stable():
    results = [result("haemoglobin", 4.1), result("glucose_fasting", 500.0, unit="mg/dL")]

    assert critical_findings(results) == critical_findings(results)
