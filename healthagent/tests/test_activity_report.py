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


# --- review fix pass ---------------------------------------------------------

NO_DATA = {
    "activity_type": "running", "duration_seconds": 2700, "data_quality": "none",
    "metrics": [], "score": None, "baseline": None,
    "history_used": {"sessions_compared": 0, "window_days": 90},
}


def test_quality_none_keeps_the_duration_readable():
    """Finding 4: the ring-dropped path must not render '—-minute session'."""
    nar = fallback_narrative(NO_DATA, [])
    out = build_report(NO_DATA, [], nar, [])
    checked, flags = verify_numbers(out, NO_DATA)
    assert "45" in checked["headline"]
    assert "—-minute" not in checked["headline"]
    assert "45" in checked["sections"][0]["body"]


def test_quality_none_still_strips_an_invented_physiological_number():
    out = build_report(NO_DATA, [], _narrative("Your heart rate averaged 148 bpm."), [])
    checked, flags = verify_numbers(out, NO_DATA)
    assert "148" not in checked["sections"][0]["body"]
    assert "quality_gate" in flags


def test_rounded_minutes_are_accepted():
    """Finding 5a: the prompt gives round(s/60); allowing only floor flags half of reports."""
    analysis = dict(ANALYSIS, duration_seconds=1790)  # round -> 30, floor -> 29
    out = build_report(analysis, [], _narrative("You ran for 30 minutes."), [])
    _, flags = verify_numbers(out, analysis)
    assert flags == []


def test_an_invented_small_delta_is_flagged():
    """Finding 5b: deltas are the likeliest fabrication and are usually small integers."""
    out = build_report(ANALYSIS, [], _narrative("Heart rate held 3 bpm lower than usual."), [])
    _, flags = verify_numbers(out, ANALYSIS)
    assert "unverified_number" in flags


def test_a_real_delta_with_units_is_accepted():
    out = build_report(ANALYSIS, [], _narrative("Heart rate held 8 bpm lower than usual."), [])
    _, flags = verify_numbers(out, ANALYSIS)
    assert flags == []


def test_a_bare_small_count_is_still_unremarkable():
    out = build_report(ANALYSIS, [], _narrative("Try this over the next 3 sessions."), [])
    _, flags = verify_numbers(out, ANALYSIS)
    assert flags == []


def test_plausible_roundings_of_a_computed_value_are_accepted():
    """A mean of 148.6 may fairly be restated as 148, 148.0, 148.6 or 149."""
    analysis = dict(
        ANALYSIS,
        metrics=[{"key": "heartRate", "value": 148.6, "min": 140, "max": 160,
                  "samples": 60, "baseline": 150, "delta": -1.4, "direction": "better"}],
    )
    for written in ("148", "148.0", "148.6", "149"):
        out = build_report(analysis, [], _narrative(f"Heart rate averaged {written} bpm."), [])
        _, flags = verify_numbers(out, analysis)
        assert flags == [], f"{written} should be accepted as a restatement of 148.6"


def test_a_genuinely_different_value_is_still_flagged():
    analysis = dict(
        ANALYSIS,
        metrics=[{"key": "heartRate", "value": 148.6, "min": 140, "max": 160,
                  "samples": 60, "baseline": 150, "delta": -1.4, "direction": "better"}],
    )
    out = build_report(analysis, [], _narrative("Heart rate averaged 162 bpm."), [])
    _, flags = verify_numbers(out, analysis)
    assert "unverified_number" in flags
