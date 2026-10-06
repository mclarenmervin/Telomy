"""Readiness v2 — the same question answered with published models.

v1's constants were invented: a 70-point anchor, a magic 1.8 divisor, a 25x
temperature penalty. They were plausible and entirely unsourced. v2 replaces
each with a model from the literature, so every number can be traced:

  Tanaka et al. (2001)      age-predicted max heart rate, 208 - 0.7 x age
  Banister (1991)           TRIMP training impulse
  Gabbett (2016)            acute:chronic workload ratio
  Buchheit (2014)           HRV and resting HR against a personal baseline
  Borbely; Dijk & Czeisler  two-process sleep-pressure model

**NOT the default.** `app.analytics.scores` still runs v1 until the shadow
period proves the port identical. Swapping the model before then would mean a
divergence with two possible causes and no way to tell them apart.

STATUS: the formulas are from the cited sources; the weights composing them are
our own judgement and are NOT yet clinically reviewed — the same caveat the
biomarker catalog carries, for the same reason.
"""

from dataclasses import dataclass, field
from datetime import datetime, timedelta
from statistics import mean, pstdev

from app.analytics import sleep as sleep_analysis
from app.analytics.dartcompat import clamp, dart_round
from app.analytics.sleep import Reading

MODEL_VERSION = "readiness-published-v2"

# Composition weights. Ours, not the literature's — the cited models each answer
# one question and say nothing about how to combine them.
WEIGHTS = {
    "Autonomic balance": 0.30,
    "Cardiac recovery": 0.20,
    "Sleep pressure": 0.30,
    "Training load": 0.20,
}

CITATIONS = {
    "Autonomic balance": "Buchheit M (2014). PMID 24578692",
    "Cardiac recovery": "Buchheit M (2014). PMID 24578692",
    "Sleep pressure": "Dijk DJ & Czeisler CA (1995). J Neurosci 15(5):3526",
    "Training load": "Banister (1991) PMID 1816431; Gabbett (2016) PMID 26758673",
}

BASELINE_DAYS = 28
ACUTE_DAYS = 7
MIN_BASELINE_READINGS = 7
MIN_NIGHTS = 3
MIN_DRIVERS = 2

MIN_PLAUSIBLE_AGE = 5
MAX_PLAUSIBLE_AGE = 120

# Gabbett's "sweet spot": inside this band, load is consistent with what the
# body has been prepared for.
ACWR_LOW, ACWR_HIGH = 0.8, 1.3


@dataclass(frozen=True)
class DriverV2:
    name: str
    score: float
    weight: float
    detail: str
    citation: str


@dataclass(frozen=True)
class ReadinessV2:
    score: int | None
    drivers: list[DriverV2] = field(default_factory=list)
    missing_inputs: list[str] = field(default_factory=list)
    recommendation: str = ""
    model_version: str = MODEL_VERSION


# ── Published formulas ───────────────────────────────────────────────────────

def max_heart_rate(age: float | None) -> float | None:
    """Tanaka: 208 - 0.7 x age. Fits older adults far better than 220 - age."""
    if age is None or not (MIN_PLAUSIBLE_AGE <= age <= MAX_PLAUSIBLE_AGE):
        return None
    return 208 - 0.7 * age


def trimp(minutes: float, mean_hr: float, resting_hr: float, max_hr: float,
          sex: str | None) -> float | None:
    """Banister's training impulse, exponentially weighted by heart-rate reserve.

    The weighting constant differs by sex in the original work; where sex is
    unknown the male constant is used and the result is still comparable with
    itself over time, which is all the ratio below needs.
    """
    if max_hr is None or resting_hr is None or max_hr <= resting_hr:
        return None
    if minutes <= 0:
        return 0.0
    reserve = (mean_hr - resting_hr) / (max_hr - resting_hr)
    if reserve <= 0:
        return 0.0
    import math

    factor = 1.67 if (sex or "").lower() == "female" else 1.92
    return minutes * reserve * 0.64 * math.exp(factor * reserve)


def acute_chronic_ratio(acute: float | None, chronic: float | None) -> float | None:
    """This week's load against the last month's.

    None without a chronic baseline: one week of data cannot tell you whether
    this week is unusual, and inventing a ratio there is how a new user gets
    told they are overtraining on day three.
    """
    if not acute and acute != 0:
        return None
    if not chronic:
        return None
    return acute / chronic


def z_score(value: float | None, mean: float | None, sd: float | None) -> float | None:
    """Distance from a person's own centre, in their own spread.

    The Buchheit discipline, and the reason v1's percentage change was wrong: a
    resting heart rate of 58 is unremarkable for one person and a warning sign
    for another.
    """
    if value is None or mean is None or not sd:
        return None
    return (value - mean) / sd


def sleep_pressure_score(nights: list[float], need: float) -> float | None:
    """Two-process: pressure accumulates across nights and discharges slowly.

    Recent nights weigh more, but a single long sleep after a bad week does not
    clear the debt — which is exactly what the model is for.
    """
    if not nights:
        return None
    # Most recent last; exponential recency weighting.
    weights = [0.85 ** (len(nights) - 1 - i) for i in range(len(nights))]
    debt = sum(
        max(0.0, need - hours) * weight for hours, weight in zip(nights, weights)
    ) / sum(weights)
    # One hour of average nightly debt costs 12 points.
    return clamp(100 - debt * 12, 0, 100)


# ── Composition ──────────────────────────────────────────────────────────────

def _day_values(readings, kind, day):
    start = day.replace(hour=0, minute=0, second=0, microsecond=0)
    return [r.value for r in readings
            if r.measurement_type == kind and start <= r.recorded_at < start + timedelta(days=1)]


def _baseline(readings, kind, day, days=BASELINE_DAYS):
    start = day - timedelta(days=days)
    return [r.value for r in readings
            if r.measurement_type == kind and start <= r.recorded_at < day]


def _autonomic(readings, day):
    today = _day_values(readings, "hrv", day)
    history = _baseline(readings, "hrv", day)
    if not today or len(history) < MIN_BASELINE_READINGS:
        return None
    z = z_score(mean(today), mean(history), pstdev(history))
    if z is None:
        return None
    # Above baseline is good; +-2 sd spans the usable range.
    return DriverV2(
        name="Autonomic balance",
        score=clamp(50 + z * 25, 0, 100),
        weight=WEIGHTS["Autonomic balance"],
        detail=f"HRV {mean(today):.0f} ms, {z:+.1f} sd from your 28-day baseline",
        citation=CITATIONS["Autonomic balance"],
    )


def _cardiac(readings, day):
    today = _day_values(readings, "restingHeartRate", day)
    history = _baseline(readings, "restingHeartRate", day)
    if not today or len(history) < MIN_BASELINE_READINGS:
        return None
    z = z_score(mean(today), mean(history), pstdev(history))
    if z is None:
        return None
    # Lower is better here, so the sign flips.
    return DriverV2(
        name="Cardiac recovery",
        score=clamp(50 - z * 25, 0, 100),
        weight=WEIGHTS["Cardiac recovery"],
        detail=f"Resting HR {mean(today):.0f} bpm, {z:+.1f} sd from baseline",
        citation=CITATIONS["Cardiac recovery"],
    )


def _nights(readings, day, count):
    hours = []
    for offset in range(count, 0, -1):
        summary = sleep_analysis.summarize(readings, day - timedelta(days=offset - 1))
        if summary.total_hours > 0:
            hours.append(summary.total_hours)
    return hours


def _sleep(readings, day, need):
    nights = _nights(readings, day, ACUTE_DAYS)
    if len(nights) < MIN_NIGHTS:
        return None
    score = sleep_pressure_score(nights, need)
    if score is None:
        return None
    return DriverV2(
        name="Sleep pressure",
        score=score,
        weight=WEIGHTS["Sleep pressure"],
        detail=f"{mean(nights):.1f} h average over {len(nights)} nights, need {need:.1f} h",
        citation=CITATIONS["Sleep pressure"],
    )


def _load(readings, day, age, sex):
    peak = max_heart_rate(age)
    resting_history = _baseline(readings, "restingHeartRate", day)
    if peak is None or len(resting_history) < MIN_BASELINE_READINGS:
        return None
    resting = mean(resting_history)

    def window(days):
        start = day - timedelta(days=days)
        total = 0.0
        for r in readings:
            if r.measurement_type != "activity" or not (start <= r.recorded_at < day):
                continue
            # Activity minutes without a heart rate are assumed moderate.
            impulse = trimp(r.value, resting + (peak - resting) * 0.6, resting, peak, sex)
            total += impulse or 0.0
        return total

    acute = window(ACUTE_DAYS)
    chronic = window(BASELINE_DAYS) / (BASELINE_DAYS / ACUTE_DAYS)
    ratio = acute_chronic_ratio(acute, chronic)
    if ratio is None:
        return None

    if ACWR_LOW <= ratio <= ACWR_HIGH:
        score = 85.0
    elif ratio < ACWR_LOW:
        # Undertrained is a mild penalty, not a warning.
        score = clamp(60 + (ratio / ACWR_LOW) * 25, 0, 85)
    else:
        score = clamp(85 - (ratio - ACWR_HIGH) * 60, 0, 85)

    return DriverV2(
        name="Training load",
        score=score,
        weight=WEIGHTS["Training load"],
        detail=f"Acute:chronic ratio {ratio:.2f}",
        citation=CITATIONS["Training load"],
    )


def calculate_v2(
    readings: list[Reading],
    date: datetime,
    age: float | None = None,
    sex: str | None = None,
    sleep_need: float = 8.0,
) -> ReadinessV2:
    day = date.replace(hour=0, minute=0, second=0, microsecond=0)

    candidates = {
        "Autonomic balance": _autonomic(readings, day),
        "Cardiac recovery": _cardiac(readings, day),
        "Sleep pressure": _sleep(readings, day, sleep_need),
        "Training load": _load(readings, day, age, sex),
    }
    drivers = [d for d in candidates.values() if d is not None]
    missing = sorted(name for name, d in candidates.items() if d is None)

    if len(drivers) < MIN_DRIVERS:
        return ReadinessV2(
            score=None,
            drivers=drivers,
            missing_inputs=missing,
            recommendation="More data is needed before estimating readiness.",
        )

    total_weight = sum(d.weight for d in drivers)
    score = int(clamp(dart_round(
        sum(d.score * d.weight for d in drivers) / total_weight), 0, 100))

    if score < 40:
        recommendation = (
            "Low readiness · the signals point to incomplete recovery. Consider "
            "easier movement today."
        )
    elif score < 70:
        recommendation = (
            "Moderate readiness · train, but keep intensity responsive to how "
            "you feel."
        )
    else:
        recommendation = "High readiness · your usual planned training looks appropriate."

    return ReadinessV2(
        score=score,
        drivers=drivers,
        missing_inputs=missing,
        recommendation=recommendation,
    )
