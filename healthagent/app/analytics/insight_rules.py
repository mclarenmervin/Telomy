"""Which observations fire is a deterministic decision; only the wording is the LLM's.

Mirrors the alert rule in CLAUDE.md: decisions are testable rules, phrasing is generative.
Thresholds here are v1 and intended to be tuned with domain input.
"""

from dataclasses import dataclass

from app.common.thresholds import get_thresholds

# Shares the central attention threshold so tuning the env moves the insight and the
# severity flag together; a local copy let them disagree about the same reading.
HR_ELEVATED_DELTA = get_thresholds().hr_attention_delta  # bpm above baseline
HR_EFFICIENT_DELTA = -5.0  # bpm below baseline
SHORT_SESSION_RATIO = 0.7  # of baseline duration
SPO2_WATCH_MIN = 92.0


@dataclass(frozen=True)
class Insight:
    id: str
    section: str  # what_went_well | watch_outs | improve
    fact: str  # a plain statement of the finding; the LLM rephrases it


def _metric(analysis, key):
    return next((m for m in analysis.get("metrics", []) if m["key"] == key), None)


def evaluate(analysis) -> list[Insight]:
    out: list[Insight] = []

    if analysis.get("data_quality") == "none":
        out.append(
            Insight(
                "no_sensor_data",
                "improve",
                "No sensor data was captured for this session; wearing the ring "
                "throughout would allow a full analysis next time.",
            )
        )

    if analysis.get("baseline") is None:
        out.append(
            Insight(
                "no_baseline",
                "improve",
                "There is not yet enough history for this activity type to compare "
                "against; a few more sessions will establish a personal baseline.",
            )
        )

    hr = _metric(analysis, "heartRate")
    if hr and hr.get("delta") is not None:
        if hr["delta"] >= HR_ELEVATED_DELTA:
            out.append(
                Insight(
                    "hr_elevated",
                    "watch_outs",
                    f"Average heart rate was {hr['delta']:.0f} bpm above the personal "
                    "baseline, which can indicate harder effort, heat, or incomplete "
                    "recovery.",
                )
            )
        elif hr["delta"] <= HR_EFFICIENT_DELTA:
            out.append(
                Insight(
                    "hr_efficient",
                    "what_went_well",
                    f"Average heart rate was {abs(hr['delta']):.0f} bpm below the "
                    "personal baseline, which suggests improving efficiency.",
                )
            )

    baseline = analysis.get("baseline") or {}
    base_duration = baseline.get("duration_seconds")
    duration = analysis.get("duration_seconds") or 0
    if base_duration and duration < base_duration * SHORT_SESSION_RATIO:
        out.append(
            Insight(
                "duration_short",
                "improve",
                "This session was notably shorter than usual for this activity.",
            )
        )

    spo2 = (analysis.get("aggregates") or {}).get("spo2")
    if spo2 and spo2.get("min") is not None and spo2["min"] < SPO2_WATCH_MIN:
        out.append(
            Insight(
                "spo2_low",
                "watch_outs",
                f"Blood oxygen dipped to {spo2['min']:.0f}% during this session.",
            )
        )

    return out
