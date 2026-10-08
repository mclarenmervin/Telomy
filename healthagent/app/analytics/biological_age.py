"""Biological age, on a published model.

The arithmetic is **PhenoAge** -- Levine ME, Lu AT, Quach A et al. (2018), *An
epigenetic biomarker of aging for lifespan and healthspan*, PMID 29676998. Nine
blood markers plus chronological age, fitted jointly against ten-year mortality
in NHANES III and validated in NHANES IV.

Not one constant in this module is ours. That is the point: the number has a
citation, a version and a reproducible input set, which is what distinguishes it
from the five-factor Dart heuristic it replaces, where a 65 bpm anchor and a
magic 1.8 divisor were plausible and entirely unsourced.

**What is ours is the refusals**, and they are the larger part of this file:

* all nine markers or no number, because the coefficients are fitted against a
  calibrated intercept and eight of them is not a reduced model, it is no model;
* a refusal rather than a clamp when a value sits outside its critical bounds;
* a bound on how far the answer may sit from chronological age;
* no number at all while the reference catalog is clinically unreviewed.

### Why PhenoAge is linear, and why that matters

The published formulation looks forbidding -- a Gompertz mortality score, then
its inverse -- but the two cancel. Substituting `ln(1-M) = -k*exp(xb)` into
`141.50225 + ln(-0.00553*ln(1-M))/0.090165` collapses the whole thing to

    PhenoAge = 142.46431 + 11.09078 * xb

So sensitivity to every marker is **constant** rather than depending on where
the person already sits. Three things follow, and all three are used below:

1. A marker's contribution can honestly be quoted *in years*, because it does
   not change with the rest of the panel.
2. Stability is analysable rather than empirical: each marker's worst move is
   its coefficient times its range times 11.09.
3. A unit-conversion error is a fixed offset, so the regression fixture in the
   tests catches one immediately.

The long form is kept in `_mortality_score` anyway, unused by the fast path, so
that the identity above is checkable against the paper rather than asserted.

### Stability, and where this departs from the plan

The plan asks that perturbing one marker by +-5% move the age by less than a
year. **PhenoAge does not have that property and cannot be given it.** RDW
carries the largest coefficient in the model (0.3306); a 5% move at a typical
13.5% RDW is 2.47 years, and MCV is 1.34. Those are the published model's
genuine sensitivities, and capping them would mean no longer computing PhenoAge
-- trading a cited number for an uncited one to satisfy a threshold.

What the plan was reaching for is that noise must not swing the answer, and that
*is* testable: at each marker's analytical imprecision (CV of 1-5%, not 5% flat)
every term moves the result by under a year. Both tests live in
`tests/test_biological_age.py`, which states the bound it asserts and why.
"""

import math
from dataclasses import dataclass, field

from app.analytics import catalog
from app.analytics.subject import Subject

MODEL_VERSION = "biological-age-phenoage-levine-2018-v1"

CITATION = "Levine ME et al. (2018) PhenoAge. PMID 29676998"

# ── The published model ──────────────────────────────────────────────────────

# Levine 2018, Table 1. Coefficients are per unit of the marker **in the
# paper's units**, which are not always the catalog's canonical units -- see
# `_PHENOAGE_UNIT` below. The intercept is calibrated against this exact set.
_COEFFICIENTS = {
    "albumin": -0.0336,              # g/L
    "creatinine": 0.0095,            # umol/L
    "glucose_fasting": 0.1953,       # mmol/L
    "hs_crp": 0.0954,                # ln(mg/dL)
    "lymphocyte_percent": -0.0120,   # %
    "mcv": 0.0268,                   # fL
    "rdw": 0.3306,                   # %
    "alkaline_phosphatase": 0.00188,  # U/L
    "wbc": 0.0554,                   # 10^3 cells/uL
}
_AGE_COEFFICIENT = 0.0804
_INTERCEPT = -19.9067

PHENOAGE_MARKERS = tuple(_COEFFICIENTS)

# Gompertz hazard parameters, and the ten-year (120-month) window the score is
# calibrated to.
_GAMMA = 0.0076927
_WINDOW_MONTHS = 120

# From the collapse described in the module docstring. Derived here rather than
# typed, so the two forms cannot drift apart.
_K = (math.exp(_GAMMA * _WINDOW_MONTHS) - 1) / _GAMMA
_SLOPE = 0.090165
_XB_CONSTANT = 141.50225 + math.log(0.00553 * _K) / _SLOPE

#: Years of biological age per unit of the linear predictor. 11.09.
YEARS_PER_XB = 1 / _SLOPE

# Canonical unit -> the paper's unit. A multiplier of 1.0 means they agree;
# every other entry is a place where quietly using the canonical value would
# shift the answer by years while still returning a plausible-looking number.
_PHENOAGE_UNIT = {
    "albumin": 10.0,       # g/dL -> g/L
    "creatinine": 88.4,    # mg/dL -> umol/L
    "glucose_fasting": 1 / 18.0182,  # mg/dL -> mmol/L
    "hs_crp": 0.1,         # mg/L -> mg/dL, then logged
    "lymphocyte_percent": 1.0,
    "mcv": 1.0,
    "rdw": 1.0,
    "alkaline_phosphatase": 1.0,
    "wbc": 1.0,
}

# hs-CRP enters as a natural log and modern assays report down to roughly
# 0.1 mg/L, so a rounded 0.0 is routine on a real report. Without a floor that
# is ln(0), and the answer is negative infinity rather than a young one. The
# floor is the assay's practical limit of detection, not an invented number.
_CRP_FLOOR_MG_L = 0.1

# ── Our guards ───────────────────────────────────────────────────────────────

#: How far the answer may sit from chronological age before we decline to be
#: more specific. Inputs bounded by their critical ranges still admit a 40-year
#: swing -- glucose alone spans 2.2 to 22.2 mmol/L inside its critical bounds --
#: and past some distance the honest answer is "see a doctor", not a number.
MAX_DIVERGENCE_YEARS = 20.0

OUTSIDE_CRITICAL = "outside_critical_range"
CLINICAL_REVIEW = "clinical_review"


@dataclass(frozen=True)
class AgeDriver:
    """One marker's contribution, in years.

    `score` is years attributable to this marker relative to the midpoint of its
    optimal band -- "your RDW adds 1.8 years compared with an optimal RDW",
    which is a sentence someone can act on. `weight` is the published
    coefficient, kept so a driver can be traced back to Table 1.
    """

    name: str
    score: float
    weight: float
    detail: str
    citation: str


@dataclass(frozen=True)
class BiologicalAgeResult:
    """Carries `score`, `drivers`, `missing_inputs` and `model_version`, which
    is what `score_snapshot.build_snapshot` reads -- the same envelope readiness
    uses, so the snapshot row needs no special case."""

    score: float | None
    chronological_age: float | None = None
    drivers: list[AgeDriver] = field(default_factory=list)
    missing_inputs: list[str] = field(default_factory=list)
    model_version: str = MODEL_VERSION
    marker_count: int = 0
    bounded: bool = False


def _mortality_score(xb: float) -> float:
    """Ten-year mortality risk, the published long way round.

    Nothing calls this on the fast path. It exists so the linear identity the
    fast path relies on can be checked against the paper rather than trusted.
    """
    return 1 - math.exp(-math.exp(xb) * _K)


def _in_phenoage_units(biomarker_id: str, canonical_value: float) -> float:
    if biomarker_id == "hs_crp":
        floored = max(float(canonical_value), _CRP_FLOOR_MG_L)
        return math.log(floored * _PHENOAGE_UNIT["hs_crp"])
    return float(canonical_value) * _PHENOAGE_UNIT[biomarker_id]


def linear_predictor(canonical: dict, age_years: float) -> float:
    """`xb` -- the model's linear predictor, from canonical-unit values."""
    total = _INTERCEPT + _AGE_COEFFICIENT * float(age_years)
    for biomarker_id, coefficient in _COEFFICIENTS.items():
        total += coefficient * _in_phenoage_units(biomarker_id, canonical[biomarker_id])
    return total


def phenoage(canonical: dict, age_years: float) -> float:
    """PhenoAge in years, with no guards at all.

    The published arithmetic and nothing else, so the model can be tested apart
    from our policy about when to show it. Callers outside this module and its
    tests should use `biological_age_for_display`.
    """
    return _XB_CONSTANT + YEARS_PER_XB * linear_predictor(canonical, age_years)


def _optimal_midpoint(biomarker_id: str) -> float | None:
    """The reference a driver's contribution is measured against.

    None for a sex-specific marker, whose optimal band depends on a sex the
    driver has no business assuming. All nine PhenoAge markers except creatinine
    have one band; creatinine's is handled by the caller passing the resolved
    sex through `_drivers`.
    """
    marker = catalog.get(biomarker_id)
    if marker is None or marker.optimal is None:
        return None
    return (marker.optimal.low + marker.optimal.high) / 2


def _reference_for(biomarker_id: str, sex: str | None) -> float | None:
    marker = catalog.get(biomarker_id)
    if marker is None:
        return None
    bands = marker.ranges_for(sex)
    if bands is None:
        return _optimal_midpoint(biomarker_id)
    _, optimal = bands
    return (optimal.low + optimal.high) / 2


def _drivers(canonical: dict, sex: str | None) -> list[AgeDriver]:
    out = []
    for biomarker_id, coefficient in _COEFFICIENTS.items():
        value = float(canonical[biomarker_id])
        reference = _reference_for(biomarker_id, sex)
        marker = catalog.get(biomarker_id)
        unit = marker.canonical_unit if marker else ""

        if reference is None:
            # No band to compare against -- a sex-specific marker with an
            # unknown sex. The marker still enters the score; we simply decline
            # to say how much of the answer it is, rather than comparing against
            # a default that would be wrong for half of everybody.
            years = 0.0
            detail = f"{value:g} {unit} (no reference band for an unknown sex)"
        else:
            years = coefficient * (
                _in_phenoage_units(biomarker_id, value)
                - _in_phenoage_units(biomarker_id, reference)
            ) * YEARS_PER_XB
            detail = (
                f"{value:g} {unit} against an optimal {reference:g} {unit}: "
                f"{years:+.1f} years"
            )

        out.append(AgeDriver(
            name=biomarker_id,
            score=years,
            weight=coefficient,
            detail=detail,
            citation=CITATION,
        ))
    return out


def biological_age(
    canonical: dict, subject: Subject, notes: dict[str, str] | None = None
) -> BiologicalAgeResult:
    """PhenoAge with our guards applied, but **not** the review gate.

    `canonical` maps biomarker_id to a value in that marker's canonical unit, as
    `biomarker_results.value_canonical` holds it. A marker that is absent, or
    present as None, is a marker selection declined to hand over -- a censored
    `<0.01`, a qualitative result, a result with no collection date -- and reads
    as missing rather than as a zero.

    `notes` maps a biomarker_id to why selection would not use the rows it had
    -- "censored", "wrong_context". A missing marker reports that reason, which
    is the difference between the app saying "we need a fasting glucose" and
    saying "glucose missing" when the user's report plainly shows one. A note
    for a marker we do have is ignored: selection records every rejected row,
    including ones where a later row was usable after all, and a note must not
    invent a gap.

    Use `biological_age_for_display` for anything that reaches a user or a
    stored row. This one is the arithmetic plus the physiology; that one adds
    the one question neither can answer.
    """
    notes = notes or {}
    missing: list[str] = list(subject.refusals)

    for biomarker_id in PHENOAGE_MARKERS:
        value = canonical.get(biomarker_id)
        if value is None:
            reason = notes.get(biomarker_id)
            missing.append(f"{biomarker_id}:{reason}" if reason else biomarker_id)
            continue
        marker = catalog.get(biomarker_id)
        if marker is not None and not marker.critical.contains(float(value)):
            # Refused, not clamped. Outside critical bounds a value is either an
            # emergency or a transcription error; clamping would quietly turn
            # the first into a merely-bad number, and `is_critical` escalates on
            # the same value independently and is not gated on this.
            missing.append(f"{biomarker_id}:{OUTSIDE_CRITICAL}")

    if subject.age_years is None or missing:
        return BiologicalAgeResult(
            score=None,
            chronological_age=subject.age_years,
            missing_inputs=sorted(set(missing)),
            marker_count=sum(
                1 for m in PHENOAGE_MARKERS if canonical.get(m) is not None
            ),
        )

    age = float(subject.age_years)
    raw = phenoage(canonical, age)
    bounded = min(max(raw, age - MAX_DIVERGENCE_YEARS), age + MAX_DIVERGENCE_YEARS)

    return BiologicalAgeResult(
        score=bounded,
        chronological_age=age,
        drivers=_drivers(canonical, subject.sex),
        missing_inputs=[],
        marker_count=len(PHENOAGE_MARKERS),
        bounded=bounded != raw,
    )


def biological_age_for_display(
    canonical: dict, subject: Subject, notes: dict[str, str] | None = None
) -> BiologicalAgeResult:
    """The result a **user** may be shown, and the only one that may be stored.

    This is `biological_age` plus the question the arithmetic cannot answer: has
    a clinician agreed the reference catalog is right? It is the same gate
    `reference_ranges.grade_for_display` applies, applied harder, because the
    claim is much stronger. "This HbA1c is high" points at one number on a
    report. "Your body is 48" is a statement about a person.

    While `biomarkers.v1.yaml` is unreviewed the number is withheld **here**,
    before it can be persisted, rather than in the app. `score_snapshots`
    carries a policy letting a user select their own rows, so a value written
    there is one client build away from being on screen; a value never written
    cannot leak. Flipping `clinical_review.reviewed` in the catalog -- with a
    named reviewer and a date, which the loader insists on -- opens this with no
    code change.

    The drivers go with it. They are per-marker contributions *in years*, so
    publishing them while withholding the total would hand over the same claim
    in instalments.
    """
    result = biological_age(canonical, subject, notes)
    if catalog.review_status().reviewed:
        return result

    return BiologicalAgeResult(
        score=None,
        chronological_age=result.chronological_age,
        drivers=[],
        missing_inputs=sorted(set(result.missing_inputs) | {CLINICAL_REVIEW}),
        marker_count=result.marker_count,
    )
