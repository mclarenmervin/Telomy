from datetime import datetime, timedelta, timezone

import pytest

from app.analytics.event_analysis import Reading, analyze_event

UTC = timezone.utc
START = datetime(2026, 9, 20, 20, 0, tzinfo=UTC)
END = datetime(2026, 9, 20, 21, 0, tzinfo=UTC)


def hr(value, at):
    return Reading("heartRate", value, at)


def baseline_hr():
    days = [1, 2, 3, 4, 5]
    values = [58, 60, 62, 60, 60]
    return [hr(v, START - timedelta(days=d, hours=8)) for d, v in zip(days, values)]


def test_no_readings_gives_none_quality_and_empty_metrics():
    result = analyze_event([], START, END)

    assert result["data_quality"] == "none"
    assert result["metrics"]["heartRate"]["during_mean"] is None
    assert result["metrics"]["heartRate"]["delta_during"] is None


def test_delta_and_z_score_against_personal_baseline():
    readings = baseline_hr() + [
        hr(80, START + timedelta(minutes=10)),
        hr(84, START + timedelta(minutes=40)),
    ]

    metric = analyze_event(readings, START, END)["metrics"]["heartRate"]

    assert metric["baseline_mean"] == pytest.approx(60)
    assert metric["during_mean"] == pytest.approx(82)
    assert metric["delta_during"] == pytest.approx(22)
    assert metric["z_during"] == pytest.approx(22 / 1.2649, rel=1e-3)


def test_before_and_after_windows_are_separate_from_during():
    readings = baseline_hr() + [
        hr(70, START - timedelta(minutes=30)),
        hr(80, START + timedelta(minutes=30)),
        hr(65, END + timedelta(minutes=30)),
    ]

    metric = analyze_event(readings, START, END)["metrics"]["heartRate"]

    assert metric["before_mean"] == pytest.approx(70)
    assert metric["during_mean"] == pytest.approx(80)
    assert metric["after_mean"] == pytest.approx(65)
    assert metric["delta_after"] == pytest.approx(5)


def test_too_few_baseline_points_means_no_baseline():
    readings = baseline_hr()[:2] + [hr(80, START + timedelta(minutes=10))]

    metric = analyze_event(readings, START, END)["metrics"]["heartRate"]

    assert metric["baseline_mean"] is None
    assert metric["delta_during"] is None
    assert metric["during_mean"] == pytest.approx(80)


def test_other_events_are_excluded_from_baseline():
    polluted_at = START - timedelta(days=6, hours=8)
    other_event = (polluted_at - timedelta(hours=1), polluted_at + timedelta(hours=1))
    readings = baseline_hr() + [hr(140, polluted_at), hr(80, START + timedelta(minutes=10))]

    with_exclusion = analyze_event(readings, START, END, other_events=[other_event])
    without_exclusion = analyze_event(readings, START, END)

    assert with_exclusion["metrics"]["heartRate"]["baseline_mean"] == pytest.approx(60)
    assert without_exclusion["metrics"]["heartRate"]["baseline_mean"] > 70


def test_quality_is_partial_when_only_some_metrics_have_data():
    readings = baseline_hr() + [hr(80, START + timedelta(minutes=10))]

    assert analyze_event(readings, START, END)["data_quality"] == "partial"


def test_quality_is_full_when_every_tracked_metric_has_baseline_and_during_data():
    readings = []
    for mtype in ("heartRate", "hrv", "temperature", "spo2"):
        for d, v in zip([1, 2, 3, 4, 5], [10, 11, 12, 11, 11]):
            readings.append(Reading(mtype, v, START - timedelta(days=d, hours=8)))
        readings.append(Reading(mtype, 20, START + timedelta(minutes=10)))

    assert analyze_event(readings, START, END)["data_quality"] == "full"
