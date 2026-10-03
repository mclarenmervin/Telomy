"""Whether a reading is concerning is a deterministic decision, never the model's.

Severity drives a warning the user may act on, so it must be reproducible and
testable: a model that has a bad generation would otherwise turn into a missed
warning or a false alarm, and neither would show up in any test.
"""

from datetime import date

from app.common.thresholds import Thresholds

NORMAL = "normal"
ATTENTION = "attention"
URGENT = "urgent"

_ORDER = {NORMAL: 0, ATTENTION: 1, URGENT: 2}

# Volume counts are not physiological signals, so they never carry severity.
NO_SEVERITY = frozenset({"steps"})

_LABELS = {
    "heartRate": "heart rate",
    "hrv": "heart rate variability",
    "spo2": "blood oxygen",
    "stress": "stress",
    "steps": "steps",
}

MIN_PLAUSIBLE_AGE = 5
MAX_PLAUSIBLE_AGE = 120


def _age_from(date_of_birth, today: date | None = None) -> int | None:
    """None for anything we cannot trust — a half-filled profile is normal."""
    if not isinstance(date_of_birth, str) or not date_of_birth.strip():
        return None
    try:
        born = date.fromisoformat(date_of_birth.strip()[:10])
    except ValueError:
        return None
    today = today or date.today()
    age = today.year - born.year - ((today.month, today.day) < (born.month, born.day))
    if not MIN_PLAUSIBLE_AGE <= age <= MAX_PLAUSIBLE_AGE:
        return None
    return age


def max_heart_rate_for(profile, thresholds: Thresholds) -> float:
    """220 - age where we know it; 195 bpm is unremarkable at 20 and alarming at 70."""
    age = _age_from((profile or {}).get("dateOfBirth"))
    if age is None:
        return thresholds.heart_rate_danger_max
    return float(220 - age)


def metric_severity(metric: dict, thresholds: Thresholds, hr_danger_max: float) -> str:
    key = metric.get("key")
    if key in NO_SEVERITY:
        return NORMAL

    low, high, delta = metric.get("min"), metric.get("max"), metric.get("delta")

    if key == "spo2":
        if low is None:
            return NORMAL
        if low < thresholds.spo2_danger_min:
            return URGENT
        if low < thresholds.spo2_attention_max:
            return ATTENTION
    elif key == "heartRate":
        if high is not None and high > hr_danger_max:
            return URGENT
        if delta is not None and delta >= thresholds.hr_attention_delta:
            return ATTENTION
    elif key == "stress":
        if delta is not None and delta >= thresholds.stress_attention_delta:
            return ATTENTION
    elif key == "hrv":
        if delta is not None and delta <= -thresholds.hrv_attention_delta:
            return ATTENTION

    return NORMAL


def roll_up(severities) -> str:
    return max(severities, key=lambda s: _ORDER.get(s, 0), default=NORMAL)


def metric_note(metric: dict, severity: str) -> str:
    """A short plain-English line, so a number reads as an insight."""
    label = _LABELS.get(metric.get("key"), metric.get("key") or "this reading")
    delta, direction = metric.get("delta"), metric.get("direction")

    if severity == URGENT:
        return f"Your {label} reached a level worth getting checked."
    if severity == ATTENTION:
        return f"Your {label} moved outside your usual range during this session."
    if delta is None:
        return f"No earlier sessions yet to compare your {label} against."
    if delta == 0:
        return f"Your {label} matched your recent average."
    movement = "higher" if delta > 0 else "lower"
    quality = "in line with" if direction is None else (
        "a good sign" if direction == "better" else "worth keeping an eye on"
    )
    return f"Your {label} was {movement} than your recent average — {quality}."


def annotate(metrics, profile, thresholds: Thresholds) -> tuple[list[dict], str]:
    """Add severity and note to each metric; return them with the report-level severity."""
    hr_danger_max = max_heart_rate_for(profile, thresholds)
    annotated = []
    for metric in metrics or []:
        severity = metric_severity(metric, thresholds, hr_danger_max)
        annotated.append({**metric, "severity": severity,
                          "note": metric_note(metric, severity)})
    return annotated, roll_up([m["severity"] for m in annotated])
