"""The deterministic fallback is the prose users see whenever narration is
unavailable — including when it is used as the remedy for a dishonest narrative.
It must never deny a finding that Python has flagged."""

from app.activity_agent.agent import _acknowledges_concern
from app.activity_agent.report import build_report, fallback_narrative

ATTENTION_CASES = {
    "hrv": {"key": "hrv", "value": 32.0, "min": 30, "max": 34,
            "baseline": 50.0, "delta": -18.0, "direction": "worse"},
    "stress": {"key": "stress", "value": 60.0, "min": 55, "max": 65,
               "baseline": 40.0, "delta": 20.0, "direction": "worse"},
    "spo2_mid_band": {"key": "spo2", "value": 93.0, "min": 93, "max": 95,
                      "baseline": 97.0, "delta": -4.0, "direction": "worse"},
}


def analysis_for(metric):
    return {"activity_type": "cycling", "duration_seconds": 1800, "metrics": [metric],
            "score": None, "baseline": {}, "data_quality": "full", "history_used": {}}


def test_fallback_never_says_nothing_flagged_against_a_raised_severity():
    for name, metric in ATTENTION_CASES.items():
        report = build_report(analysis_for(metric), [], fallback_narrative(
            analysis_for(metric), []), [])

        assert report["severity"] == "attention", name
        watch = next(s for s in report["sections"] if s["id"] == "watch_outs")
        assert "Nothing flagged" not in watch["body"], f"{name}: {watch['body']}"


def test_the_fallback_satisfies_the_very_check_that_selects_it():
    """The guardrails node replaces a dishonest narrative with this prose. If the
    replacement itself fails the check, the remedy is self-defeating."""
    for name, metric in ATTENTION_CASES.items():
        analysis = analysis_for(metric)
        report = build_report(analysis, [], fallback_narrative(analysis, []), [])

        assert _acknowledges_concern(report) is True, f"{name}: {report['sections']}"


def test_a_normal_session_still_reads_as_unremarkable():
    normal = {"key": "steps", "value": 4000.0, "min": 4000, "max": 4000,
              "baseline": 3900.0, "delta": 100.0, "direction": "better"}
    analysis = analysis_for(normal)

    report = build_report(analysis, [], fallback_narrative(analysis, []), [])

    assert report["severity"] == "normal"
    watch = next(s for s in report["sections"] if s["id"] == "watch_outs")
    assert "Nothing flagged" in watch["body"]
