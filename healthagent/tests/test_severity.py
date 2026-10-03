from datetime import date

from app.analytics.severity import (
    ATTENTION,
    NORMAL,
    URGENT,
    annotate,
    max_heart_rate_for,
    metric_severity,
    roll_up,
)
from app.common.thresholds import Thresholds

T = Thresholds()


def m(key, **kw):
    base = {"key": key, "value": 1, "min": None, "max": None, "baseline": None,
            "delta": None, "direction": None}
    base.update(kw)
    return base


def test_spo2_below_danger_is_urgent():
    assert metric_severity(m("spo2", min=88), T, 200.0) == URGENT


def test_spo2_in_the_gap_between_danger_and_attention_is_attention():
    """90-94 must not fall through both rules — the readings that matter most."""
    assert metric_severity(m("spo2", min=91), T, 200.0) == ATTENTION
    assert metric_severity(m("spo2", min=94), T, 200.0) == ATTENTION


def test_spo2_at_the_attention_boundary_is_normal():
    assert metric_severity(m("spo2", min=95), T, 200.0) == NORMAL


def test_heart_rate_above_danger_is_urgent():
    assert metric_severity(m("heartRate", max=205), T, 200.0) == URGENT


def test_heart_rate_elevated_against_own_baseline_is_attention():
    assert metric_severity(m("heartRate", delta=15.0), T, 200.0) == ATTENTION


def test_hrv_sharply_down_is_attention():
    assert metric_severity(m("hrv", delta=-15.0), T, 200.0) == ATTENTION


def test_steps_never_carries_severity():
    """A volume count, not a physiological signal."""
    assert metric_severity(m("steps", delta=9999, max=99999), T, 200.0) == NORMAL


def test_missing_min_and_max_do_not_raise():
    """Ragged samples mean a field can aggregate without min/max present."""
    assert metric_severity(m("spo2"), T, 200.0) == NORMAL
    assert metric_severity(m("heartRate"), T, 200.0) == NORMAL


def test_roll_up_takes_the_worst():
    assert roll_up([NORMAL, ATTENTION, NORMAL]) == ATTENTION
    assert roll_up([ATTENTION, URGENT]) == URGENT
    assert roll_up([]) == NORMAL


def test_max_heart_rate_is_age_adjusted():
    """Expected age is derived from today's date so the test never goes stale."""
    birth_year = 1956
    # Born 1 January: the birthday has always passed, so age is a plain year difference.
    expected_age = date.today().year - birth_year
    assert max_heart_rate_for({"dateOfBirth": f"{birth_year}-01-01"}, T) == 220 - expected_age


def test_malformed_date_of_birth_falls_back_to_the_configured_default():
    """Must not crash the worker on a half-filled profile."""
    for dob in ("", "1990", "not-a-date", None, "2099-01-01"):
        assert max_heart_rate_for({"dateOfBirth": dob}, T) == T.heart_rate_danger_max
    assert max_heart_rate_for({}, T) == T.heart_rate_danger_max
    assert max_heart_rate_for(None, T) == T.heart_rate_danger_max


def test_annotate_adds_severity_and_note_and_returns_report_level():
    metrics = [m("spo2", value=93, min=93, baseline=97, delta=-4, direction="worse"),
               m("steps", value=4000)]

    annotated, overall = annotate(metrics, {}, T)

    assert annotated[0]["severity"] == ATTENTION
    assert annotated[0]["note"]
    assert annotated[1]["severity"] == NORMAL
    assert overall == ATTENTION


def test_annotate_on_an_empty_metric_list_is_normal():
    """data_quality 'none' must not crash on an empty max()."""
    annotated, overall = annotate([], {}, T)

    assert annotated == []
    assert overall == NORMAL


def test_stress_rise_at_the_threshold_is_attention_just_below_is_normal():
    assert metric_severity(m("stress", delta=15), T, 200.0) == ATTENTION
    assert metric_severity(m("stress", delta=14), T, 200.0) == NORMAL
    assert metric_severity(m("stress"), T, 200.0) == NORMAL


def test_spo2_at_the_danger_boundary_is_attention_not_urgent():
    """Strict '<': a flip to '<=' would raise a false urgent at exactly 90."""
    assert metric_severity(m("spo2", min=90), T, 200.0) == ATTENTION
    assert metric_severity(m("spo2", min=89.9), T, 200.0) == URGENT


def test_heart_rate_exactly_at_the_danger_max_is_normal():
    assert metric_severity(m("heartRate", max=200), T, 200.0) == NORMAL
    assert metric_severity(m("heartRate", max=200.1), T, 200.0) == URGENT


def test_deltas_just_below_the_attention_threshold_are_normal():
    assert metric_severity(m("heartRate", delta=14.9), T, 200.0) == NORMAL
    assert metric_severity(m("stress", delta=14.9), T, 200.0) == NORMAL
    assert metric_severity(m("hrv", delta=-14), T, 200.0) == NORMAL
    assert metric_severity(m("hrv", delta=-14.9), T, 200.0) == NORMAL


def test_thresholds_are_read_from_the_passed_instance_not_inlined():
    """Custom values must move the boundaries, proving nothing is hardcoded."""
    custom = Thresholds(spo2_danger_min=88.0, spo2_attention_max=92.0,
                        hr_attention_delta=20.0, stress_attention_delta=5.0,
                        hrv_attention_delta=30.0)

    assert metric_severity(m("spo2", min=89), custom, 200.0) == ATTENTION
    assert metric_severity(m("spo2", min=87), custom, 200.0) == URGENT
    assert metric_severity(m("spo2", min=93), custom, 200.0) == NORMAL
    assert metric_severity(m("heartRate", delta=18), custom, 200.0) == NORMAL
    assert metric_severity(m("heartRate", delta=20), custom, 200.0) == ATTENTION
    assert metric_severity(m("stress", delta=5), custom, 200.0) == ATTENTION
    assert metric_severity(m("hrv", delta=-20), custom, 200.0) == NORMAL
    assert metric_severity(m("hrv", delta=-30), custom, 200.0) == ATTENTION


def test_default_heart_rate_ceiling_comes_from_the_passed_instance():
    custom = Thresholds(heart_rate_danger_max=180.0)

    assert max_heart_rate_for({}, custom) == 180.0
