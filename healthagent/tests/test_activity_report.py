from app.activity_agent.report import (
    Narrative,
    NarrativeSection,
    build_report,
    fallback_narrative,
    verify_numbers,
)

ANALYSIS = {
    "activity_type": "running",
    "duration_seconds": 1800,
    "data_quality": "full",
    "score": {"value": 72, "scale": 100, "label": "solid",
              "basis": "vs your last 5 sessions", "score_version": 1},
    "baseline": {"heartRate": 150, "duration_seconds": 1800, "sessions_compared": 5},
    "metrics": [
        {"key": "heartRate", "value": 142, "min": 120, "max": 170, "samples": 60,
         "baseline": 150, "delta": -8, "direction": "better"}
    ],
    "history_used": {"sessions_compared": 5},
}

SECTION_IDS = ["what_happened", "what_changed", "what_went_well", "watch_outs", "improve"]


def _narrative(body):
    return Narrative(
        headline="A steady run.",
        sections=[NarrativeSection(id=i, title=i, body=body) for i in SECTION_IDS],
    )


def test_report_envelope_is_assembled_from_deterministic_values():
    out = build_report(ANALYSIS, [], _narrative("Nothing notable."), [])
    assert out["schema_version"] == 1
    assert out["score"]["value"] == 72
    assert out["metrics"][0]["delta"] == -8
    assert [s["id"] for s in out["sections"]] == SECTION_IDS
    assert out["data_gaps"] == []


def test_a_missing_section_still_appears_in_the_envelope():
    partial = Narrative(
        headline="Short.",
        sections=[NarrativeSection(id="what_happened", title="t", body="b")],
    )
    out = build_report(ANALYSIS, [], partial, [])
    assert [s["id"] for s in out["sections"]] == SECTION_IDS
    assert out["sections"][-1]["body"] == ""


def test_numbers_present_in_the_metrics_are_accepted():
    out = build_report(ANALYSIS, [], _narrative("Your average was 142 bpm, 8 below 150."), [])
    _, flags = verify_numbers(out, ANALYSIS)
    assert flags == []


def test_an_invented_number_is_flagged():
    """Review Focus 5."""
    out = build_report(ANALYSIS, [], _narrative("You burned 918 calories."), [])
    _, flags = verify_numbers(out, ANALYSIS)
    assert "unverified_number" in flags


def test_quality_none_blocks_confident_numeric_claims():
    analysis = dict(ANALYSIS, data_quality="none", metrics=[], score=None, baseline=None)
    out = build_report(analysis, [], _narrative("Your heart rate averaged 142 bpm."), [])
    checked, flags = verify_numbers(out, analysis)
    assert "quality_gate" in flags
    assert "142" not in checked["sections"][0]["body"]


def test_fallback_narrative_needs_no_model():
    nar = fallback_narrative(ANALYSIS, [{"id": "x", "section": "improve", "fact": "Do more."}])
    assert nar.headline
    assert len(nar.sections) == 5
    assert "Do more." in next(s.body for s in nar.sections if s.id == "improve")


def test_data_gaps_are_carried_into_the_envelope():
    gaps = [{"source": "documents", "status": "unconfigured", "reason": "not configured"}]
    out = build_report(ANALYSIS, [], _narrative("Fine."), gaps)
    assert out["data_gaps"] == gaps
