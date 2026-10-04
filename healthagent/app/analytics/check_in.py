"""Whether to interrupt the user mid-event is a deterministic decision.

The LLM is never asked *whether* to speak, only how to word a reason that has
already fired — so a bad generation cannot invent an alert, and a quiet event
costs no inference at all (NFR-4.3, NFR-5.2).

Returns at most one reason per check: the notification stays focused, and the
reason doubles as the dedupe key (`kind="check_in:<reason>"`).
"""

from dataclasses import dataclass

from app.common.thresholds import Thresholds, get_thresholds

REASON_SPO2 = "spo2_low"
REASON_HR = "hr_elevated"
REASON_HRV = "hrv_suppressed"

# The reason is part of the prediction's `kind`, which is what makes the existing
# unique (event_id, kind) constraint the dedupe mechanism. Defined here, imported
# by the loader and the graph — two copies of this string would silently split
# "already sent" from "what we write".
CHECK_IN_PREFIX = "check_in:"

# Most urgent first. Blood oxygen outranks the others because it is the only one
# of the three that can warrant leaving the event entirely.
PRIORITY = (REASON_SPO2, REASON_HR, REASON_HRV)


@dataclass(frozen=True)
class CheckIn:
    reason: str
    fact: str  # a plain statement of what fired; the LLM rephrases it


def _spo2(metric: dict, thresholds: Thresholds) -> CheckIn | None:
    during = metric.get("during_mean")
    if during is None or during >= thresholds.spo2_danger_min:
        return None
    return CheckIn(
        REASON_SPO2,
        f"Blood oxygen is averaging {during:.0f}% during this event, below "
        f"{thresholds.spo2_danger_min:.0f}%.",
    )


def _heart_rate(metric: dict, thresholds: Thresholds) -> CheckIn | None:
    delta, z = metric.get("delta_during"), metric.get("z_during")
    # Both are required: a raw delta alone would nag a naturally variable person,
    # and a z-score alone would fire on a tiny absolute change.
    if delta is None or z is None:
        return None
    if delta < thresholds.check_in_hr_delta or z < thresholds.check_in_hr_z:
        return None
    return CheckIn(
        REASON_HR,
        f"Heart rate is running {delta:.0f} bpm above the personal baseline so "
        f"far in this event ({z:.1f} standard deviations outside the usual spread).",
    )


def _hrv(metric: dict, thresholds: Thresholds) -> CheckIn | None:
    baseline, delta = metric.get("baseline_mean"), metric.get("delta_during")
    if not baseline or baseline <= 0 or delta is None or delta >= 0:
        return None
    drop_pct = (-delta / baseline) * 100
    if drop_pct < thresholds.check_in_hrv_drop_pct:
        return None
    return CheckIn(
        REASON_HRV,
        f"HRV is down {drop_pct:.0f}% against the personal baseline so far in "
        "this event.",
    )


_RULES = {
    REASON_SPO2: ("spo2", _spo2),
    REASON_HR: ("heartRate", _heart_rate),
    REASON_HRV: ("hrv", _hrv),
}


def evaluate_check_in(
    analysis: dict,
    elapsed_seconds: float,
    already_sent=(),
    thresholds: Thresholds | None = None,
) -> CheckIn | None:
    """One reason to speak, or None. Silence is the expected outcome."""
    thresholds = thresholds or get_thresholds()

    # No readings near the window: there is nothing to have an opinion about.
    if analysis.get("data_quality") == "none":
        return None
    # Too early for a window mean to say anything about the event.
    if elapsed_seconds < thresholds.check_in_min_elapsed_seconds:
        return None

    metrics = analysis.get("metrics") or {}
    already_sent = set(already_sent)
    for reason in PRIORITY:
        if reason in already_sent:
            continue
        metric_key, rule = _RULES[reason]
        fired = rule(metrics.get(metric_key) or {}, thresholds)
        if fired is not None:
            return fired
    return None
