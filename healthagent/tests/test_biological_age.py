"""Biological age on a published model.

The arithmetic is Levine ME et al. (2018), PMID 29676998 -- nine markers plus
chronological age, fitted jointly against ten-year mortality. These tests check
three separate things, and the distinction matters:

1. **The published model, reproduced faithfully.** No constant here is ours.
2. **The guards around it**, which are ours: a refusal when a marker is absent,
   a refusal when one is physiologically implausible, and a bound on how far the
   answer may sit from chronological age.
3. **The clinical-review gate.** A biological age is a far stronger claim than
   "this HbA1c is high", and `biomarkers.v1.yaml` is not reviewed. The number
   must not reach a row the phone can read.
"""

import math

import pytest

from app.analytics import catalog
from app.analytics.biological_age import (
    _mortality_score,
    MAX_DIVERGENCE_YEARS,
    MODEL_VERSION,
    PHENOAGE_MARKERS,
    YEARS_PER_XB,
    biological_age,
    biological_age_for_display,
    phenoage,
)
from app.analytics.subject import Subject

# A plausible 45-year-old, in the catalog's canonical units. Not mid-range on
# every marker -- a fixture that clean proves almost nothing.
TYPICAL = {
    "albumin": 4.2,              # g/dL
    "creatinine": 0.96,          # mg/dL
    "glucose_fasting": 97.0,     # mg/dL
    "hs_crp": 1.5,               # mg/L
    "lymphocyte_percent": 28.0,  # %
    "mcv": 90.0,                 # fL
    "rdw": 13.5,                 # %
    "alkaline_phosphatase": 75.0,  # U/L
    "wbc": 6.8,                  # 10^3/uL
}

ADULT = Subject(age_years=45.0, sex="female")


def values(**overrides) -> dict:
    merged = dict(TYPICAL)
    merged.update(overrides)
    return merged


@pytest.fixture
def reviewed(monkeypatch):
    """Pretend a clinician has signed the catalog off.

    Everything except the gate itself is tested through this, because testing a
    model whose output is always None tests nothing.
    """
    monkeypatch.setattr(
        catalog, "review_status",
        lambda: catalog.ClinicalReview(True, "Dr A Reviewer", "2026-10-01"),
    )


# ── The published arithmetic ─────────────────────────────────────────────────

def test_phenoage_is_linear_in_the_linear_predictor():
    """A property of the published formulation worth pinning down, because the
    whole stability argument rests on it.

    The Gompertz mortality score and its inverse cancel: substituting
    ln(1-M) = -k*exp(xb) into the published PhenoAge expression collapses it to
    `142.46431 + 11.09078 * xb`. Sensitivity to any marker is therefore constant
    rather than depending on where the person sits, which is what makes a
    per-marker contribution in years a meaningful number to show someone.
    """
    low = phenoage(values(rdw=12.0), age_years=45.0)
    mid = phenoage(values(rdw=13.0), age_years=45.0)
    high = phenoage(values(rdw=14.0), age_years=45.0)

    assert mid - low == pytest.approx(high - mid, abs=1e-9)
    assert mid - low == pytest.approx(0.3306 * YEARS_PER_XB, rel=1e-6)


def test_the_linear_form_agrees_with_the_published_long_way_round():
    """The fast path is a derived identity, not the paper's own expression, and
    the derivation is the thing most likely to be wrong. So compute the age both
    ways -- through the Gompertz mortality score and its inverse exactly as
    published, and through `142.46431 + 11.09078*xb` -- and require agreement.

    Checked across a wide span of xb, because the two forms could coincide at
    one point by accident and nowhere else.
    """
    for xb in (-14.0, -11.0, -9.7, -8.0, -5.0, -2.0):
        mortality = _mortality_score(xb)
        published = 141.50225 + math.log(-0.00553 * math.log(1 - mortality)) / 0.090165
        linear = 142.46431 + 11.09078 * xb

        assert published == pytest.approx(linear, abs=1e-4), xb


def test_a_plausible_middle_aged_profile_lands_near_its_chronological_age():
    """Regression anchor. Hand-computed from the published coefficient table;
    if this moves, a coefficient or a unit conversion has changed."""
    assert phenoage(TYPICAL, age_years=45.0) == pytest.approx(43.07, abs=0.1)


def test_a_better_profile_scores_younger_than_a_worse_one():
    better = phenoage(
        values(albumin=4.6, hs_crp=0.4, rdw=12.2, lymphocyte_percent=34.0),
        age_years=45.0,
    )
    worse = phenoage(
        values(albumin=3.7, hs_crp=6.0, rdw=15.2, lymphocyte_percent=18.0),
        age_years=45.0,
    )

    assert better < 45.0 < worse


def test_every_published_coefficient_pushes_in_the_direction_the_paper_gives():
    """Sign check on all nine. A transposed sign would be invisible in a single
    number and would invert the advice built on it."""
    raises = ("creatinine", "glucose_fasting", "hs_crp", "mcv", "rdw",
              "alkaline_phosphatase", "wbc")
    lowers = ("albumin", "lymphocyte_percent")
    base = phenoage(TYPICAL, age_years=45.0)

    for marker in raises:
        assert phenoage(values(**{marker: TYPICAL[marker] * 1.1}),
                        age_years=45.0) > base, marker
    for marker in lowers:
        assert phenoage(values(**{marker: TYPICAL[marker] * 1.1}),
                        age_years=45.0) < base, marker


def test_units_are_converted_into_the_published_model_s_own_units():
    """The catalog's canonical units are not PhenoAge's. Albumin is g/dL here
    and g/L in the paper, creatinine mg/dL and umol/L, glucose mg/dL and mmol/L,
    CRP mg/L and ln(mg/dL). Getting one wrong shifts every result by years while
    still looking like a number."""
    # 4.2 g/dL is 42 g/L; the term is therefore -0.0336 * 42, not -0.0336 * 4.2.
    delta = phenoage(values(albumin=4.3), age_years=45.0) - phenoage(
        TYPICAL, age_years=45.0)

    assert delta == pytest.approx(-0.0336 * 1.0 * YEARS_PER_XB, rel=1e-6)


def test_a_crp_of_zero_does_not_produce_an_infinite_age():
    """The model takes ln(CRP). Assays report down to about 0.1 mg/L and a
    rounded 0.0 is routine; without a floor it is ln(0) and the answer is -inf
    rather than a young one."""
    result = phenoage(values(hs_crp=0.0), age_years=45.0)

    assert math.isfinite(result)
    assert result == phenoage(values(hs_crp=0.1), age_years=45.0)


# ── Guards: what we refuse ───────────────────────────────────────────────────

def test_all_nine_markers_are_required(reviewed):
    """The coefficients are fitted jointly against a calibrated intercept, so
    eight markers is not a reduced model -- it is no model."""
    for marker in PHENOAGE_MARKERS:
        short = values()
        del short[marker]
        result = biological_age(short, ADULT)

        assert result.score is None, marker
        assert marker in result.missing_inputs, marker


def test_a_complete_panel_produces_a_number(reviewed):
    result = biological_age(TYPICAL, ADULT)

    assert result.score == pytest.approx(43.07, abs=0.1)
    assert result.missing_inputs == []
    assert result.marker_count == 9
    assert result.model_version == MODEL_VERSION


def test_a_value_outside_its_critical_range_refuses_rather_than_being_clamped(
    reviewed,
):
    """A potassium of 7 or a haemoglobin of 4 is an emergency or a transcription
    error. Neither should become a biological age, and clamping would quietly
    turn an emergency into a merely-bad number. The escalation path fires on the
    same value independently and is not gated on this."""
    result = biological_age(values(wbc=80.0), ADULT)  # critical high is 50

    assert result.score is None
    assert "wbc:outside_critical_range" in result.missing_inputs


def test_the_answer_is_bounded_to_a_window_around_chronological_age(reviewed):
    """Inputs bounded by their critical ranges still admit a 40-year swing --
    glucose alone spans 2.2 to 22.2 mmol/L inside its critical bounds. Past some
    distance the honest answer is "see a doctor", not a number."""
    result = biological_age(
        values(glucose_fasting=390.0, rdw=29.0, hs_crp=95.0, wbc=45.0), ADULT
    )

    assert result.score == pytest.approx(45.0 + MAX_DIVERGENCE_YEARS)
    assert result.bounded is True


def test_an_unbounded_answer_does_not_claim_to_have_been_bounded(reviewed):
    assert biological_age(TYPICAL, ADULT).bounded is False


def test_a_subject_we_refused_to_resolve_is_not_scored(reviewed):
    """Pregnancy, a minor, a missing date of birth. The subject resolver already
    decided; this must not score around it."""
    pregnant = Subject(age_years=31.0, sex="female", refusals=("pregnancy",))
    result = biological_age(TYPICAL, pregnant)

    assert result.score is None
    assert "pregnancy" in result.missing_inputs


def test_a_missing_chronological_age_refuses(reviewed):
    result = biological_age(TYPICAL, Subject(age_years=None, sex="female",
                                             refusals=("date_of_birth",)))

    assert result.score is None
    assert "date_of_birth" in result.missing_inputs


def test_a_censored_or_qualitative_value_never_reaches_the_arithmetic(reviewed):
    """None is what selection hands over for a result it would not use. It must
    read as a missing marker, not as a zero."""
    result = biological_age(values(albumin=None), ADULT)

    assert result.score is None
    assert "albumin" in result.missing_inputs


# ── Stability ────────────────────────────────────────────────────────────────

# The plan asks for "perturb one marker +-5%, age moves <1 year". That is not a
# property published PhenoAge has: RDW carries the largest coefficient in the
# model (0.3306) and a 5% move at a typical 13.5% RDW is 2.47 years; MCV is
# 1.34. Both are the model's genuine sensitivity, not an implementation fault,
# and capping them would mean no longer computing PhenoAge.
#
# So this asserts the model's real bound, and the test below asserts the
# property the plan was reaching for -- that assay noise does not swing the
# answer -- using each marker's actual analytical imprecision instead.
MAX_MOVE_PER_5_PERCENT_YEARS = 2.5

# Typical analytical CVs for modern autoanalysers and haematology counters.
ASSAY_CV = {
    "albumin": 0.02,
    "creatinine": 0.03,
    "glucose_fasting": 0.02,
    "hs_crp": 0.05,
    "lymphocyte_percent": 0.03,
    "mcv": 0.01,
    "rdw": 0.02,
    "alkaline_phosphatase": 0.03,
    "wbc": 0.03,
}


@pytest.mark.parametrize("marker", PHENOAGE_MARKERS)
def test_a_five_percent_perturbation_moves_the_age_within_the_model_s_bound(marker):
    base = phenoage(TYPICAL, age_years=45.0)

    for factor in (0.95, 1.05):
        moved = phenoage(values(**{marker: TYPICAL[marker] * factor}),
                         age_years=45.0)
        assert abs(moved - base) < MAX_MOVE_PER_5_PERCENT_YEARS, marker


@pytest.mark.parametrize("marker", PHENOAGE_MARKERS)
def test_assay_imprecision_moves_the_age_by_less_than_a_year(marker):
    """The useful stability question: could re-running the same blood on the
    same analyser change what we tell someone? It must not."""
    base = phenoage(TYPICAL, age_years=45.0)
    cv = ASSAY_CV[marker]

    for factor in (1 - cv, 1 + cv):
        moved = phenoage(values(**{marker: TYPICAL[marker] * factor}),
                         age_years=45.0)
        assert abs(moved - base) < 1.0, marker


def test_the_same_inputs_always_give_the_same_answer():
    """Reproducibility starts here. A snapshot can only be recomputed from its
    own inputs if the arithmetic is deterministic."""
    assert phenoage(TYPICAL, 45.0) == phenoage(dict(reversed(list(TYPICAL.items()))), 45.0)


# ── Drivers ──────────────────────────────────────────────────────────────────

def test_drivers_name_every_marker_with_its_contribution_in_years(reviewed):
    result = biological_age(TYPICAL, ADULT)

    assert {d.name for d in result.drivers} == set(PHENOAGE_MARKERS)
    assert all(d.citation for d in result.drivers)


def test_a_driver_s_contribution_is_measured_against_the_optimal_band(reviewed):
    """"Your RDW adds 1.8 years compared with an optimal RDW" is a sentence
    someone can act on. A raw coefficient is not."""
    # The optimal band is 11.5-13.0, so its midpoint -- the reference a
    # contribution is measured from -- is 12.25.
    good = biological_age(values(rdw=11.8), ADULT)
    bad = biological_age(values(rdw=15.0), ADULT)

    rdw_good = next(d for d in good.drivers if d.name == "rdw")
    rdw_bad = next(d for d in bad.drivers if d.name == "rdw")

    assert rdw_good.score < 0 < rdw_bad.score
    assert rdw_bad.score == pytest.approx(
        0.3306 * (15.0 - 12.25) * YEARS_PER_XB, rel=1e-6
    )


# ── The clinical-review gate ─────────────────────────────────────────────────

def test_no_age_is_produced_while_the_catalog_is_unreviewed():
    """The decision taken for F4: while `clinical_review.reviewed` is false the
    number is never written anywhere the phone can read.

    A biological age is a far stronger claim than a single marker's verdict, and
    `score_snapshots` already carries a policy letting a user select their own
    rows -- so gating this in the app would put the number one client build away
    from a user. It is withheld at the source instead.
    """
    result = biological_age_for_display(TYPICAL, ADULT)

    assert result.score is None
    assert "clinical_review" in result.missing_inputs


def test_the_gate_withholds_the_number_from_the_drivers_too():
    """Drivers are per-marker contributions *in years*. Publishing them while
    withholding the total would hand over the same claim in parts."""
    result = biological_age_for_display(TYPICAL, ADULT)

    assert result.drivers == []


def test_the_gate_opens_when_a_clinician_signs_the_catalog_off(reviewed):
    """One field in biomarkers.v1.yaml, no code change."""
    result = biological_age_for_display(TYPICAL, ADULT)

    assert result.score == pytest.approx(43.07, abs=0.1)
    assert "clinical_review" not in result.missing_inputs


def test_the_gate_does_not_invent_a_number_for_an_unscorable_subject(reviewed):
    result = biological_age_for_display(values(albumin=None), ADULT)

    assert result.score is None
