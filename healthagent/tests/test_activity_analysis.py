from app.analytics.activity_analysis import (
    aggregate_samples,
    analyze_activity,
    assess_data_quality,
    build_baseline,
    compute_score,
    is_plausible_session,
)


def test_aggregates_are_ragged_safe():
    """Review Focus 1: mobile omits null keys, so fields vary per sample."""
    samples = [
        {"heartRate": 140, "hrv": 40},
        {"heartRate": 150},
        {"heartRate": 160, "spo2": 97},
    ]
    agg = aggregate_samples(samples)
    assert agg["heartRate"]["n"] == 3
    assert agg["heartRate"]["mean"] == 150
    assert agg["hrv"]["n"] == 1
    assert agg["spo2"]["n"] == 1
    assert "stress" not in agg


def test_non_numeric_sample_values_are_ignored():
    agg = aggregate_samples([{"heartRate": "bad"}, {"heartRate": True}, {"heartRate": 100}])
    assert agg["heartRate"]["n"] == 1


def test_empty_samples_give_no_aggregates_and_quality_none():
    assert aggregate_samples([]) == {}
    assert assess_data_quality({}) == "none"


def test_forgot_to_stop_session_is_rejected_from_baseline():
    """Review Focus 3: a 14-hour run must not poison the baseline."""
    assert is_plausible_session({"duration_seconds": 1800}) is True
    assert is_plausible_session({"duration_seconds": 14 * 3600}) is False
    assert is_plausible_session({"duration_seconds": 5}) is False

    past = [
        {"duration_seconds": 1800, "summary": {"heartRate": 150}},
        {"duration_seconds": 1800, "summary": {"heartRate": 150}},
        {"duration_seconds": 1800, "summary": {"heartRate": 150}},
        {"duration_seconds": 14 * 3600, "summary": {"heartRate": 60}},
    ]
    baseline = build_baseline(past)
    assert baseline["sessions_compared"] == 3
    assert baseline["heartRate"] == 150


def test_baseline_needs_three_plausible_sessions():
    two = [{"duration_seconds": 1800, "summary": {"heartRate": 150}}] * 2
    assert build_baseline(two) is None


def test_score_is_omitted_without_a_baseline():
    assert compute_score({"heartRate": {"mean": 140}}, None, 1800) is None


def test_score_rewards_lower_heart_rate_at_equal_duration():
    baseline = {"heartRate": 150, "duration_seconds": 1800, "sessions_compared": 5}
    better = compute_score({"heartRate": {"mean": 140}}, baseline, 1800)
    worse = compute_score({"heartRate": {"mean": 165}}, baseline, 1800)
    assert better["value"] > worse["value"]
    assert 0 <= worse["value"] <= 100
    assert 0 <= better["value"] <= 100
    assert better["scale"] == 100
    assert better["basis"].startswith("vs your last 5")


def test_score_is_deterministic():
    baseline = {"heartRate": 150, "duration_seconds": 1800, "sessions_compared": 5}
    agg = {"heartRate": {"mean": 143}}
    assert compute_score(agg, baseline, 1800) == compute_score(agg, baseline, 1800)


def test_analyze_activity_assembles_metrics_and_history():
    session = {
        "activity_type": "running",
        "duration_seconds": 1800,
        "samples": [{"heartRate": 140}, {"heartRate": 144}],
    }
    past = [{"duration_seconds": 1800, "summary": {"heartRate": 150}}] * 3
    out = analyze_activity(session, past)
    hr = next(m for m in out["metrics"] if m["key"] == "heartRate")
    assert hr["value"] == 142
    assert hr["baseline"] == 150
    assert hr["delta"] == -8
    assert hr["direction"] == "better"
    assert out["data_quality"] in {"full", "partial"}
    assert out["history_used"]["sessions_compared"] == 3
