import math
import random
import uuid
from datetime import datetime, timedelta

from app.analytics.event_analysis import to_readings  # noqa: F401  (re-exported)

STEP = timedelta(minutes=30)
AFTER_EFFECT = timedelta(minutes=60)

BASE = {
    "heartRate": (62.0, 2.0, "bpm"),
    "hrv": (55.0, 4.0, "ms"),
    "temperature": (36.5, 0.1, "°C"),
    "spo2": (97.0, 0.6, "%"),
}
EFFECTS = {
    "alcohol": {"heartRate": 15, "hrv": -18, "temperature": 0.4, "spo2": -0.5},
    "sauna": {"heartRate": 35, "hrv": -20, "temperature": 1.0, "spo2": 0.0},
    "exercise": {"heartRate": 55, "hrv": -25, "temperature": 0.6, "spo2": -0.5},
    "eating": {"heartRate": 8, "hrv": -5, "temperature": 0.15, "spo2": 0.0},
}


def _effect(metric: str, at: datetime, events) -> float:
    total = 0.0
    for event_type, start, end in events:
        size = EFFECTS.get(event_type, {}).get(metric, 0.0)
        if start <= at <= end:
            total += size
        elif end < at <= end + AFTER_EFFECT:
            total += size / 2
    return total


def generate_readings(
    user_id: str, now: datetime, days: int = 14, seed: int = 1, events=()
) -> list[dict]:
    """Fake wearable readings for one person, shaped like health_measurements rows."""
    rng = random.Random(seed)
    rows = []
    steps = int(timedelta(days=days) / STEP)
    for k in range(steps + 1):
        at = now - k * STEP
        circadian = math.sin(2 * math.pi * (at.hour - 14) / 24)
        for metric, (mean, noise, unit) in BASE.items():
            wave = 3.0 * circadian if metric == "heartRate" else 0.0
            value = mean + wave + _effect(metric, at, events) + rng.gauss(0, noise)
            if metric == "spo2":
                value = min(value, 100.0)
            rows.append(
                {
                    "id": str(uuid.UUID(int=rng.getrandbits(128))),
                    "user_id": user_id,
                    "measurement_type": metric,
                    "value": round(value, 2),
                    "unit": unit,
                    "recorded_at": at.isoformat(),
                    "source": "wearable",
                    "device_id": "synthetic-ring",
                    "quality": "measured",
                }
            )
    return rows
