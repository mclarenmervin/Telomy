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


# --- review fix pass ---------------------------------------------------------


def test_malformed_sample_entries_are_dropped_not_fatal():
    """Finding 6: a null or scalar inside samples must not lose the whole report."""
    agg = aggregate_samples([{"heartRate": 140}, None, "garbage", 7, {"heartRate": 150}])
    assert agg["heartRate"]["n"] == 2


def test_zero_baseline_heart_rate_does_not_raise():
    """Finding 12: a ring with no skin contact can report 0, not omit the key."""
    baseline = {"heartRate": 0, "duration_seconds": 1800, "sessions_compared": 5}
    assert compute_score({"heartRate": {"mean": 140}}, baseline, 1800) is None


def test_a_real_long_session_is_still_analysed():
    """Finding 7: a 7-hour ride is excluded from baselines but must still get a report."""
    from app.analytics.activity_analysis import is_analyzable

    seven_hours = {"duration_seconds": 7 * 3600}
    assert is_plausible_session(seven_hours) is False  # not baseline material
    assert is_analyzable(seven_hours) is True  # but still worth a report


def test_an_accidental_tap_is_not_analysed():
    from app.analytics.activity_analysis import is_analyzable

    assert is_analyzable({"duration_seconds": 4}) is False
    assert is_analyzable({"duration_seconds": 95}) is True  # a short mobility block counts


def test_an_implausibly_long_session_is_marked_suspect():
    session = {"activity_type": "cycling", "duration_seconds": 9 * 3600, "samples": []}
    assert analyze_activity(session, [])["duration_suspect"] is True
    normal = {"activity_type": "cycling", "duration_seconds": 1800, "samples": []}
    assert analyze_activity(normal, [])["duration_suspect"] is False


def test_history_used_reports_the_window():
    """Finding 14: the UI renders 'vs your last N over M days' and needs both."""
    past = [{"duration_seconds": 1800, "summary": {"heartRate": 150}}] * 3
    out = analyze_activity({"activity_type": "running", "duration_seconds": 1800,
                            "samples": [{"heartRate": 142}]}, past)
    assert out["history_used"]["sessions_compared"] == 3
    assert out["history_used"]["window_days"] > 0
