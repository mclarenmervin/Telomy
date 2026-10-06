"""Readiness, ported from the Flutter app at identical behaviour.

**This is step one of closing the dual-math defect, and it is deliberately not
an improvement.** Readiness is currently computed in Dart on the phone and
narrated from Python by the agent, so the two cannot agree. The fix adds the
server number first, proves it identical with golden fixtures that both
languages run, and only then changes the model — because changing the model and
moving it at the same time makes any divergence impossible to attribute.

The published-model version (Tanaka, TRIMP/Banister, Buchheit, two-process)
replaces the hand-tuned constants below in a separate, reviewable diff. Until
then every weight and magic number here is a faithful copy, odd ones included.

Source: mobile/lib/features/readiness/data/readiness_service.dart
"""

from dataclasses import dataclass, field
from datetime import datetime, timedelta

from app.analytics import sleep as sleep_analysis
from app.analytics.dartcompat import average, clamp, dart_round
from app.analytics.sleep import Reading

MODEL_VERSION = "readiness-v1"

WEIGHTS = {
    "HRV": 0.22,
    "Resting heart rate": 0.18,
    "Sleep duration": 0.22,
    "Sleep consistency": 0.12,
    "Temperature deviation": 0.10,
    "Previous activity": 0.08,
    "Stress": 0.08,
}

BASELINE_DAYS = 30
MIN_BASELINE_READINGS = 3
MIN_BEDTIMES = 3
MIN_DRIVERS = 2


@dataclass(frozen=True)
class Driver:
    name: str
    score: float
    weight: float
    detail: str


@dataclass(frozen=True)
class Readiness:
    score: int | None
    drivers: list[Driver] = field(default_factory=list)
    missing_inputs: list[str] = field(default_factory=list)
    recommendation: str = ""
    model_version: str = MODEL_VERSION


def _start_of_day(value: datetime) -> datetime:
    return value.replace(hour=0, minute=0, second=0, microsecond=0)


def _values_for_day(readings, measurement_type: str, day: datetime) -> list[float]:
    start = _start_of_day(day)
    end = start + timedelta(days=1)
    return [r.value for r in readings
            if r.measurement_type == measurement_type and start <= r.recorded_at < end]


def _baseline_values(readings, measurement_type: str, day: datetime) -> list[float]:
    start = day - timedelta(days=BASELINE_DAYS)
    return [r.value for r in readings
            if r.measurement_type == measurement_type and start <= r.recorded_at < day]


def _night_minute(value: datetime) -> float:
    """Minutes into a night that runs noon-to-noon, so 23:30 and 00:30 are an
    hour apart rather than twenty-three."""
    hour = value.hour + 24 if value.hour < 12 else value.hour
    return float(hour * 60 + value.minute)


def _baseline_driver(readings, measurement_type, day, name, higher_is_better):
    current = _values_for_day(readings, measurement_type, day)
    baseline = _baseline_values(readings, measurement_type, day)
    if not current or len(baseline) < MIN_BASELINE_READINGS:
        return None
    now = average(current)
    normal = average(baseline)
    change = 0 if normal == 0 else (now - normal) / normal
    score = clamp(70 + (change if higher_is_better else -change) * 100, 0, 100)
    return Driver(
        name=name,
        score=score,
        weight=WEIGHTS[name],
        detail=f"{now:.1f} vs {normal:.1f} 30-day baseline",
    )


def calculate(
    readings: list[Reading],
    date: datetime,
    sleep_goal: float = 8,
    activity_goal: float = 30,
) -> Readiness:
    day = _start_of_day(date)
    drivers: list[Driver] = []
    missing: list[str] = []

    for measurement_type, name, higher_is_better in (
        ("hrv", "HRV", True),
        ("restingHeartRate", "Resting heart rate", False),
    ):
        driver = _baseline_driver(readings, measurement_type, day, name, higher_is_better)
        drivers.append(driver) if driver else missing.append(name)

    night = sleep_analysis.summarize(readings, day)
    if night.total_hours > 0:
        duration_score = clamp(
            100 - abs(night.total_hours - sleep_goal) / sleep_goal * 100, 0, 100
        )
        drivers.append(Driver(
            name="Sleep duration",
            score=duration_score,
            weight=WEIGHTS["Sleep duration"],
            detail=f"{night.total_hours:.1f} h of {sleep_goal:.1f} h goal",
        ))

        bedtimes = []
        for offset in range(1, 30):
            previous = sleep_analysis.summarize(readings, day - timedelta(days=offset))
            if previous.bedtime is not None:
                bedtimes.append(previous.bedtime)

        if len(bedtimes) >= MIN_BEDTIMES and night.bedtime is not None:
            baseline = average(_night_minute(b) for b in bedtimes)
            difference = abs(_night_minute(night.bedtime) - baseline)
            # Past twelve hours apart, the shorter way round the clock is meant.
            wrapped = 1440 - difference if difference > 720 else difference
            drivers.append(Driver(
                name="Sleep consistency",
                score=clamp(100 - wrapped / 1.8, 0, 100),
                weight=WEIGHTS["Sleep consistency"],
                detail=f"{dart_round(wrapped)} min from your usual bedtime",
            ))
        else:
            missing.append("Sleep consistency")
    else:
        missing.extend(["Sleep duration", "Sleep consistency"])

    current_temp = _values_for_day(readings, "temperature", day)
    baseline_temp = _baseline_values(readings, "temperature", day)
    if current_temp and len(baseline_temp) >= MIN_BASELINE_READINGS:
        deviation = abs(average(current_temp) - average(baseline_temp))
        drivers.append(Driver(
            name="Temperature deviation",
            score=clamp(100 - deviation * 25, 0, 100),
            weight=WEIGHTS["Temperature deviation"],
            detail=f"{deviation:.1f} °C from baseline",
        ))
    else:
        missing.append("Temperature deviation")

    yesterday = _values_for_day(readings, "activity", day - timedelta(days=1))
    if yesterday:
        minutes = sum(yesterday)
        load = 0 if activity_goal <= 0 else minutes / activity_goal
        score = 80.0 if load <= 1 else clamp(80 - (load - 1) * 40, 0, 80)
        drivers.append(Driver(
            name="Previous activity",
            score=score,
            weight=WEIGHTS["Previous activity"],
            detail=f"{dart_round(minutes)} active min yesterday",
        ))
    else:
        missing.append("Previous activity")

    stress_values = _values_for_day(readings, "stress", day)
    if stress_values:
        stress = clamp(average(stress_values), 0, 100)
        drivers.append(Driver(
            name="Stress",
            score=100 - stress,
            weight=WEIGHTS["Stress"],
            detail=f"{dart_round(stress)} / 100 recorded stress proxy",
        ))
    else:
        missing.append("Stress")

    if len(drivers) < MIN_DRIVERS:
        # Refuse rather than guess — the discipline the rest of this codebase
        # already applies when inputs are thin.
        return Readiness(
            score=None,
            drivers=drivers,
            missing_inputs=missing,
            recommendation="More data is needed before estimating readiness.",
        )

    total_weight = sum(d.weight for d in drivers)
    raw = sum(d.score * d.weight for d in drivers) / total_weight
    score = int(clamp(dart_round(raw), 0, 100))

    if score < 40:
        recommendation = (
            "Low readiness estimate · consider recovery-focused movement and "
            "reduce training intensity."
        )
    elif score < 70:
        recommendation = (
            "Moderate readiness estimate · keep training controlled and respond "
            "to how you feel."
        )
    else:
        recommendation = (
            "High readiness estimate · normal planned training may be "
            "appropriate if you feel well."
        )

    return Readiness(
        score=score,
        drivers=drivers,
        missing_inputs=missing,
        recommendation=recommendation,
    )
