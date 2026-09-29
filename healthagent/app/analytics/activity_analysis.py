"""Deterministic activity analysis. No I/O, no LLM — every number here is arithmetic."""

from statistics import mean

TRACKED_FIELDS = ("heartRate", "hrv", "spo2", "stress", "steps")
LOWER_IS_BETTER = frozenset({"heartRate", "stress"})
MIN_BASELINE_SESSIONS = 3
MIN_DURATION_SECONDS = 120
MAX_PLAUSIBLE_DURATION_SECONDS = 21600  # 6h — beyond this, assume "forgot to stop"
SCORE_VERSION = 1


def _numeric(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def aggregate_samples(samples) -> dict:
    """Per-field aggregates. Ragged-safe: each field uses only samples containing it."""
    out: dict[str, dict] = {}
    for field in TRACKED_FIELDS:
        values = [s[field] for s in samples if _numeric(s.get(field))]
        if values:
            out[field] = {
                "mean": round(mean(values), 1),
                "min": min(values),
                "max": max(values),
                "n": len(values),
            }
    return out


def is_plausible_session(session) -> bool:
    seconds = session.get("duration_seconds") or 0
    return MIN_DURATION_SECONDS <= seconds <= MAX_PLAUSIBLE_DURATION_SECONDS


def build_baseline(past):
    """Mean of each field across plausible past sessions, or None if too few."""
    plausible = [p for p in past if is_plausible_session(p)]
    if len(plausible) < MIN_BASELINE_SESSIONS:
        return None
    baseline = {"sessions_compared": len(plausible)}
    baseline["duration_seconds"] = round(mean(p["duration_seconds"] for p in plausible))
    for field in TRACKED_FIELDS:
        values = [
            p["summary"][field]
            for p in plausible
            if _numeric((p.get("summary") or {}).get(field))
        ]
        if values:
            baseline[field] = round(mean(values), 1)
    return baseline


def assess_data_quality(aggregates) -> str:
    if not aggregates:
        return "none"
    return "full" if "heartRate" in aggregates and len(aggregates) >= 2 else "partial"


def compute_score(aggregates, baseline, duration_seconds):
    """0-100, per activity type. Deterministic by construction — never LLM-chosen."""
    if baseline is None or "heartRate" not in aggregates or "heartRate" not in baseline:
        return None
    hr = aggregates["heartRate"]["mean"]
    hr_base = baseline["heartRate"]
    # Lower heart rate than baseline is better; clamp influence at 20% deviation.
    hr_ratio = max(-0.2, min(0.2, (hr_base - hr) / hr_base))
    hr_points = hr_ratio / 0.2 * 30

    base_duration = baseline.get("duration_seconds") or duration_seconds or 1
    dur_ratio = max(0.5, min(1.5, (duration_seconds or 0) / base_duration))
    dur_points = max(-20.0, min(20.0, (dur_ratio - 1) * 40))

    value = int(max(0, min(100, round(50 + hr_points + dur_points))))
    if value >= 75:
        label = "strong"
    elif value >= 55:
        label = "solid"
    elif value >= 40:
        label = "easy"
    else:
        label = "below par"
    return {
        "value": value,
        "scale": 100,
        "label": label,
        "basis": f"vs your last {baseline['sessions_compared']} sessions",
        "score_version": SCORE_VERSION,
    }


def analyze_activity(session, past) -> dict:
    aggregates = aggregate_samples(session.get("samples") or [])
    baseline = build_baseline(past)
    duration = session.get("duration_seconds") or 0

    metrics = []
    for key, agg in aggregates.items():
        base = (baseline or {}).get(key)
        delta = round(agg["mean"] - base, 1) if base is not None else None
        direction = None
        if delta is not None and delta != 0:
            improved = delta < 0 if key in LOWER_IS_BETTER else delta > 0
            direction = "better" if improved else "worse"
        metrics.append(
            {
                "key": key,
                "value": agg["mean"],
                "min": agg["min"],
                "max": agg["max"],
                "samples": agg["n"],
                "baseline": base,
                "delta": delta,
                "direction": direction,
            }
        )

    return {
        "activity_type": session.get("activity_type"),
        "duration_seconds": duration,
        "aggregates": aggregates,
        "baseline": baseline,
        "metrics": metrics,
        "score": compute_score(aggregates, baseline, duration),
        "data_quality": assess_data_quality(aggregates),
        "history_used": {"sessions_compared": (baseline or {}).get("sessions_compared", 0)},
    }
