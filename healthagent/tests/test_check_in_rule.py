from app.analytics.check_in import (
    PRIORITY,
    REASON_HR,
    REASON_HRV,
    REASON_SPO2,
    evaluate_check_in,
)
from app.common.thresholds import Thresholds, get_thresholds

ELAPSED = 1800.0  # 30 minutes in — past the min-elapsed guard


def analysis(quality="full", **metrics):
    base = {
        "heartRate": {"baseline_mean": 60.0, "during_mean": 62.0,
                      "delta_during": 2.0, "z_during": 0.5},
        "hrv": {"baseline_mean": 55.0, "during_mean": 54.0,
                "delta_during": -1.0, "z_during": -0.2},
        "temperature": {"baseline_mean": 36.5, "during_mean": 36.5,
                        "delta_during": 0.0, "z_during": 0.0},
        "spo2": {"baseline_mean": 97.0, "during_mean": 97.0,
                 "delta_during": 0.0, "z_during": 0.0},
    }
    base.update(metrics)
    return {"data_quality": quality, "metrics": base}


def test_a_quiet_event_says_nothing():
    assert evaluate_check_in(analysis(), ELAPSED) is None


def test_elevated_heart_rate_fires_with_the_delta_in_the_fact():
    result = evaluate_check_in(
        analysis(heartRate={"baseline_mean": 60.0, "during_mean": 76.0,
                            "delta_during": 16.0, "z_during": 3.1}),
        ELAPSED,
    )

    assert result is not None
    assert result.reason == REASON_HR
    assert "16" in result.fact


def test_heart_rate_above_the_delta_but_within_normal_spread_stays_silent():
    """A naturally variable person must not be nagged by a raw delta alone."""
    result = evaluate_check_in(
        analysis(heartRate={"baseline_mean": 60.0, "during_mean": 76.0,
                            "delta_during": 16.0, "z_during": 0.8}),
        ELAPSED,
    )

    assert result is None


def test_suppressed_hrv_fires_on_percentage_drop():
    result = evaluate_check_in(
        analysis(hrv={"baseline_mean": 55.0, "during_mean": 38.0,
                      "delta_during": -17.0, "z_during": -2.4}),
        ELAPSED,
    )

    assert result is not None
    assert result.reason == REASON_HRV


def test_low_spo2_outranks_everything_else():
    result = evaluate_check_in(
        analysis(
            spo2={"baseline_mean": 97.0, "during_mean": 88.0,
                  "delta_during": -9.0, "z_during": -4.0},
            heartRate={"baseline_mean": 60.0, "during_mean": 90.0,
                       "delta_during": 30.0, "z_during": 5.0},
        ),
        ELAPSED,
    )

    assert result is not None
    assert result.reason == REASON_SPO2
    assert PRIORITY.index(REASON_SPO2) == 0


def test_only_one_reason_is_returned_per_check():
    result = evaluate_check_in(
        analysis(
            heartRate={"baseline_mean": 60.0, "during_mean": 90.0,
                       "delta_during": 30.0, "z_during": 5.0},
            hrv={"baseline_mean": 55.0, "during_mean": 30.0,
                 "delta_during": -25.0, "z_during": -4.0},
        ),
        ELAPSED,
    )

    assert result is not None
    assert result.reason == REASON_HR


def test_a_reason_already_sent_is_skipped_and_the_next_one_can_fire():
    loud = analysis(
        heartRate={"baseline_mean": 60.0, "during_mean": 90.0,
                   "delta_during": 30.0, "z_during": 5.0},
        hrv={"baseline_mean": 55.0, "during_mean": 30.0,
             "delta_during": -25.0, "z_during": -4.0},
    )

    result = evaluate_check_in(loud, ELAPSED, already_sent={REASON_HR})

    assert result is not None
    assert result.reason == REASON_HRV


def test_every_reason_already_sent_means_silence():
    loud = analysis(
        heartRate={"baseline_mean": 60.0, "during_mean": 90.0,
                   "delta_during": 30.0, "z_during": 5.0},
    )

    assert evaluate_check_in(loud, ELAPSED, already_sent={REASON_HR}) is None


def test_no_baseline_yet_stays_silent():
    """Regression: a new user has no baseline; alerting against None is nonsense."""
    result = evaluate_check_in(
        analysis(heartRate={"baseline_mean": None, "during_mean": 95.0,
                            "delta_during": None, "z_during": None}),
        ELAPSED,
    )

    assert result is None


def test_missing_sensor_data_stays_silent():
    assert evaluate_check_in(analysis(quality="none"), ELAPSED) is None


def test_too_early_in_the_event_stays_silent():
    loud = analysis(
        heartRate={"baseline_mean": 60.0, "during_mean": 90.0,
                   "delta_during": 30.0, "z_during": 5.0},
    )

    assert evaluate_check_in(loud, elapsed_seconds=60.0) is None


def test_min_elapsed_boundary_fires_exactly_at_the_threshold():
    loud = analysis(
        heartRate={"baseline_mean": 60.0, "during_mean": 90.0,
                   "delta_during": 30.0, "z_during": 5.0},
    )
    minimum = get_thresholds().check_in_min_elapsed_seconds

    assert evaluate_check_in(loud, elapsed_seconds=minimum) is not None


def test_thresholds_can_be_tuned_without_touching_the_rule():
    strict = Thresholds(check_in_hr_delta=40.0)
    loud = analysis(
        heartRate={"baseline_mean": 60.0, "during_mean": 90.0,
                   "delta_during": 30.0, "z_during": 5.0},
    )

    assert evaluate_check_in(loud, ELAPSED, thresholds=strict) is None
