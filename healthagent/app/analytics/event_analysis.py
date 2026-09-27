from dataclasses import dataclass
from datetime import datetime, timedelta
from statistics import mean, pstdev

TRACKED = ("heartRate", "hrv", "temperature", "spo2")
WINDOW = timedelta(minutes=60)
BASELINE_DAYS = 14
MIN_BASELINE_POINTS = 5


@dataclass(frozen=True)
class Reading:
    measurement_type: str
    value: float
    recorded_at: datetime


def _mean(values: list[float]) -> float | None:
    return mean(values) if values else None


def _in_other_event(at: datetime, other_events) -> bool:
    return any(s <= at <= e + WINDOW for s, e in other_events)


def _analyze_metric(series: list[Reading], start: datetime, end: datetime, other_events) -> dict:
    before = [r.value for r in series if start - WINDOW <= r.recorded_at < start]
    during = [r.value for r in series if start <= r.recorded_at <= end]
    after = [r.value for r in series if end < r.recorded_at <= end + WINDOW]
    baseline = [
        r.value
        for r in series
        if start - timedelta(days=BASELINE_DAYS) <= r.recorded_at < start - WINDOW
        and not _in_other_event(r.recorded_at, other_events)
    ]

    has_baseline = len(baseline) >= MIN_BASELINE_POINTS
    baseline_mean = mean(baseline) if has_baseline else None
    baseline_std = pstdev(baseline) if has_baseline else None
    during_mean = _mean(during)
    after_mean = _mean(after)

    def delta(value):
        if value is None or baseline_mean is None:
            return None
        return value - baseline_mean

    delta_during = delta(during_mean)
    z_during = delta_during / baseline_std if delta_during is not None and baseline_std else None

    return {
        "baseline_mean": baseline_mean,
        "baseline_std": baseline_std,
        "baseline_points": len(baseline),
        "before_mean": _mean(before),
        "during_mean": during_mean,
        "after_mean": after_mean,
        "delta_during": delta_during,
        "delta_after": delta(after_mean),
        "z_during": z_during,
    }


def analyze_event(
    readings: list[Reading],
    start: datetime,
    end: datetime,
    other_events=(),
) -> dict:
    metrics = {
        mtype: _analyze_metric(
            [r for r in readings if r.measurement_type == mtype], start, end, other_events
        )
        for mtype in TRACKED
    }

    near_event = any(
        r.measurement_type in TRACKED and start - WINDOW <= r.recorded_at <= end + WINDOW
        for r in readings
    )
    complete = all(
        m["during_mean"] is not None and m["baseline_mean"] is not None
        for m in metrics.values()
    )
    if not near_event:
        quality = "none"
    elif complete:
        quality = "full"
    else:
        quality = "partial"

    return {"data_quality": quality, "metrics": metrics}


def to_readings(rows: list[dict]) -> list[Reading]:
    return [
        Reading(
            row["measurement_type"],
            float(row["value"]),
            datetime.fromisoformat(row["recorded_at"]),
        )
        for row in rows
    ]
