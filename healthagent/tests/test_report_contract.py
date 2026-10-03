import re

from app.activity_agent.report import SCHEMA_VERSION, Narrative, NarrativeSection, build_report
from app.analytics.severity import ATTENTION, NORMAL, URGENT


def narrative():
    return Narrative(
        headline="A steady session.",
        sections=[NarrativeSection(id=sid, title=sid, body="Body text.")
                  for sid in ("what_happened", "what_changed", "what_went_well",
                              "watch_outs", "improve")],
    )


def analysis(metrics):
    return {"activity_type": "cycling", "duration_seconds": 1800, "metrics": metrics,
            "score": None, "baseline": {}, "data_quality": "full", "history_used": {}}


def test_schema_version_is_two():
    assert SCHEMA_VERSION == 2


def test_report_carries_severity_and_annotated_metrics():
    report = build_report(
        analysis([{"key": "spo2", "value": 93, "min": 93, "max": 97,
                   "baseline": 97, "delta": -4, "direction": "worse"}]),
        [], narrative(), [],
    )

    assert report["severity"] == ATTENTION
    assert report["metrics"][0]["severity"] == ATTENTION
    assert report["metrics"][0]["note"]


def test_escalation_is_always_present_and_routine_when_normal():
    report = build_report(analysis([]), [], narrative(), [])

    assert report["severity"] == NORMAL
    assert report["escalation"]["level"] == "routine"
    assert report["escalation"]["action"] == "book_consultation"


def test_escalation_level_rises_with_severity():
    report = build_report(
        analysis([{"key": "spo2", "value": 88, "min": 88, "max": 92,
                   "baseline": 97, "delta": -9, "direction": "worse"}]),
        [], narrative(), [],
    )

    assert report["severity"] == URGENT
    assert report["escalation"]["level"] == "urgent"


def test_escalation_never_contains_a_phone_number():
    """Baked-in numbers cannot be changed without a redeploy and vary by region."""
    for metrics in ([], [{"key": "spo2", "value": 88, "min": 88, "max": 90,
                          "baseline": 97, "delta": -9, "direction": "worse"}]):
        escalation = build_report(analysis(metrics), [], narrative(), [])["escalation"]
        joined = f"{escalation['title']} {escalation['body']}"
        assert not re.search(r"\+?\d[\d\s().-]{6,}", joined)


def test_age_adjusted_max_heart_rate_is_used_when_the_profile_has_a_birthdate():
    metrics = [{"key": "heartRate", "value": 180, "min": 150, "max": 185,
                "baseline": 150, "delta": 30, "direction": "worse"}]

    without = build_report(analysis(metrics), [], narrative(), [])
    with_dob = build_report(analysis(metrics), [], narrative(), [],
                            profile={"dateOfBirth": "1956-01-01"})

    assert without["severity"] == ATTENTION      # 185 < 200 default
    assert with_dob["severity"] == URGENT        # 185 > 220-70
