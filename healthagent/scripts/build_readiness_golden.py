"""Generates the readiness parity fixtures that Python and Dart both run.

The fixtures are the contract that makes the dual-math fix provable: the port is
only "identical" if two independent implementations agree on the same inputs to
1e-6. Scenarios deliberately include the cases where a port usually drifts —
rounding at .5, interval union across devices, midnight-spanning sleep, and the
bedtime wrap-around.

Expected values are produced by the Python implementation; the Dart test is the
check. A disagreement means one of them is wrong, and the fixture says which
inputs to look at.

    .venv/bin/python scripts/build_readiness_golden.py
"""

import json
from dataclasses import asdict
from datetime import datetime, timedelta
from pathlib import Path

from app.analytics.readiness import calculate
from app.analytics.sleep import Reading

OUT = Path(__file__).resolve().parents[2] / "golden" / "readiness"
# Naive wall-clock on purpose. The app parses stored timestamps with
# .toLocal(), so any offset in a fixture would shift day boundaries by the test
# machine's timezone and make parity depend on where it runs. These fixtures
# test the algorithm; timezone handling is a separate concern and a real one —
# see docs on computing a user's day server-side.
DAY = datetime(2026, 10, 1)


def reading(kind, value, at, ended_at=None):
    return Reading(kind, value, at, ended_at)


def steady_baseline(day, days=30, hrv=55.0, rhr=60.0, temp=36.5):
    out = []
    for offset in range(1, days + 1):
        at = day - timedelta(days=offset, hours=-3)
        out += [reading("hrv", hrv, at),
                reading("restingHeartRate", rhr, at),
                reading("temperature", temp, at)]
    return out


def night(day, bed_hour=23, bed_minute=0, hours=7.5, offset_days=0):
    """One asleep span ending on `day - offset_days`.

    A night is attributed to the day it ends on, so a 23:00 bedtime starts the
    evening before while a 00:10 one starts on the day itself. Getting this
    wrong is how the wrap-around scenario silently stopped testing anything.
    """
    ends_on = day - timedelta(days=offset_days)
    starts_on = ends_on - timedelta(days=1) if bed_hour >= 12 else ends_on
    start = starts_on.replace(hour=bed_hour, minute=bed_minute)
    end = start + timedelta(hours=hours)
    assert end.date() == ends_on.date(), f"night does not end on {ends_on.date()}"
    return [reading("sleep", hours, start, end)]


def scenario_full():
    rs = steady_baseline(DAY)
    for offset in range(0, 10):
        rs += night(DAY, offset_days=offset)
    rs += [
        reading("hrv", 62.0, DAY.replace(hour=7)),
        reading("restingHeartRate", 57.0, DAY.replace(hour=7)),
        reading("temperature", 36.7, DAY.replace(hour=7)),
        reading("stress", 28.0, DAY.replace(hour=12)),
        reading("activity", 35.0, DAY - timedelta(days=1)),
    ]
    return "full_seven_drivers", rs, {}


def scenario_sparse():
    """Fewer than two drivers must refuse rather than guess."""
    return "too_sparse_to_score", [reading("stress", 40.0, DAY.replace(hour=9))], {}


def scenario_overlapping_sleep():
    """A ring and a watch both recording the same night must not be counted twice."""
    rs = steady_baseline(DAY)
    start = (DAY - timedelta(days=1)).replace(hour=23)
    rs += [
        reading("sleep", 7.0, start, start + timedelta(hours=7)),
        reading("sleepDeep", 6.0, start + timedelta(hours=1),
                start + timedelta(hours=7)),
    ]
    for offset in range(1, 6):
        rs += night(DAY, offset_days=offset)
    rs += [reading("stress", 30.0, DAY.replace(hour=10))]
    return "overlapping_sleep_sources", rs, {}


def scenario_bedtime_wraparound():
    """Bedtimes either side of midnight are an hour apart, not twenty-three."""
    rs = steady_baseline(DAY)
    for offset in range(1, 8):
        rs += night(DAY, bed_hour=23, bed_minute=50, offset_days=offset)
    rs += night(DAY, bed_hour=0, bed_minute=10, hours=6.0, offset_days=0)
    rs += [
        reading("hrv", 56.0, DAY.replace(hour=8)),
        reading("restingHeartRate", 59.0, DAY.replace(hour=8)),
        reading("stress", 25.0, DAY.replace(hour=10)),
    ]
    return "bedtime_wraps_midnight", rs, {}


def scenario_rounding_edge():
    """Inputs chosen to land the weighted mean on a .5 boundary, where Dart
    rounds away from zero and Python would round to even."""
    rs = steady_baseline(DAY, hrv=50.0, rhr=50.0)
    rs += [
        reading("hrv", 50.0, DAY.replace(hour=7)),
        reading("restingHeartRate", 50.0, DAY.replace(hour=7)),
        reading("stress", 30.5, DAY.replace(hour=9)),
    ]
    return "rounding_half_boundary", rs, {}


def scenario_activity_over_goal():
    rs = steady_baseline(DAY)
    rs += [
        reading("hrv", 55.0, DAY.replace(hour=7)),
        reading("activity", 120.0, DAY - timedelta(days=1)),
        reading("stress", 55.0, DAY.replace(hour=9)),
    ]
    return "activity_well_over_goal", rs, {"activity_goal": 30}


def scenario_zero_baseline():
    """A baseline of zero must not divide by zero."""
    rs = []
    for offset in range(1, 5):
        rs.append(reading("hrv", 0.0, DAY - timedelta(days=offset)))
    rs += [
        reading("hrv", 10.0, DAY.replace(hour=7)),
        reading("stress", 20.0, DAY.replace(hour=9)),
    ]
    return "zero_baseline", rs, {}


SCENARIOS = [
    scenario_full, scenario_sparse, scenario_overlapping_sleep,
    scenario_bedtime_wraparound, scenario_rounding_edge,
    scenario_activity_over_goal, scenario_zero_baseline,
]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for build in SCENARIOS:
        name, readings, options = build()
        result = calculate(readings, DAY, **options)
        payload = {
            "name": name,
            "date": DAY.isoformat(),
            "sleep_goal": options.get("sleep_goal", 8),
            "activity_goal": options.get("activity_goal", 30),
            "measurements": [
                {
                    "measurement_type": r.measurement_type,
                    "value": r.value,
                    "recorded_at": r.recorded_at.isoformat(),
                    **({"ended_at": r.ended_at.isoformat()} if r.ended_at else {}),
                }
                for r in readings
            ],
            "expected": {
                "score": result.score,
                "model_version": result.model_version,
                "missing_inputs": sorted(result.missing_inputs),
                "drivers": sorted(
                    [{"name": d.name, "score": round(d.score, 9), "weight": d.weight}
                     for d in result.drivers],
                    key=lambda d: d["name"],
                ),
            },
        }
        (OUT / f"{name}.json").write_text(json.dumps(payload, indent=2) + "\n")
        print(f"{name}: score={result.score} drivers={len(result.drivers)}")


if __name__ == "__main__":
    main()
