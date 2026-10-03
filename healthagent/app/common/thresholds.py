"""Severity thresholds, in one place and validated.

These decide whether a reading is reported as dangerous, so a silent
misconfiguration is a safety failure, not a config nuisance: `SPO2_DANGER_MIN=0`
would switch off the urgent warning with nothing in any log to show it. Every
value is therefore range-checked, and a bad one falls back loudly.
"""

import os
from dataclasses import dataclass, fields

from app.common.logging_config import get_logger

logger = get_logger(__name__)


@dataclass(frozen=True)
class Thresholds:
    spo2_danger_min: float = 90.0
    spo2_attention_max: float = 95.0
    heart_rate_danger_max: float = 200.0
    hr_attention_delta: float = 15.0
    stress_attention_delta: float = 15.0
    hrv_attention_delta: float = 15.0


# (low, high) inclusive bounds a value must fall within to be believed.
RANGES = {
    "spo2_danger_min": (85.0, 99.0),
    "spo2_attention_max": (85.0, 99.0),
    "heart_rate_danger_max": (150.0, 230.0),
    "hr_attention_delta": (5.0, 50.0),
    "stress_attention_delta": (5.0, 50.0),
    "hrv_attention_delta": (5.0, 50.0),
}


def _read(name: str, default: float) -> float:
    raw = os.environ.get(name.upper())
    if raw is None or raw == "":
        return default
    try:
        value = float(raw)
    except ValueError:
        logger.error(f"{name.upper()}={raw!r} is not a number; using {default}")
        return default
    low, high = RANGES[name]
    if not low <= value <= high:
        logger.error(
            f"{name.upper()}={value} is outside {low}-{high}; using {default}"
        )
        return default
    return value


def get_thresholds() -> Thresholds:
    values = {f.name: _read(f.name, f.default) for f in fields(Thresholds)}
    return Thresholds(**values)


def describe(thresholds: Thresholds) -> str:
    """One line naming every effective value, logged at worker start."""
    return " ".join(f"{f.name}={getattr(thresholds, f.name)}" for f in fields(Thresholds))
