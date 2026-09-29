from app.analytics.insight_rules import evaluate


def _analysis(**over):
    base = {
        "data_quality": "full",
        "duration_seconds": 1800,
        "baseline": {"heartRate": 150, "duration_seconds": 1800, "sessions_compared": 5},
        "aggregates": {"heartRate": {"mean": 150, "min": 120, "max": 170, "n": 100}},
        "metrics": [
            {"key": "heartRate", "value": 150, "baseline": 150, "delta": 0, "direction": None}
        ],
    }
    base.update(over)
    return base


def _ids(analysis):
    return {i.id for i in evaluate(analysis)}


def test_no_baseline_asks_for_more_sessions():
    assert "no_baseline" in _ids(_analysis(baseline=None, score=None))


def test_missing_data_asks_user_to_wear_the_ring():
    assert "no_sensor_data" in _ids(_analysis(data_quality="none", aggregates={}, metrics=[]))


def test_elevated_heart_rate_fires_pacing_advice():
    ids = _ids(
        _analysis(
            metrics=[
                {"key": "heartRate", "value": 172, "baseline": 150, "delta": 22,
                 "direction": "worse"}
            ]
        )
    )
    assert "hr_elevated" in ids


def test_lower_heart_rate_same_duration_is_praised():
    ids = _ids(
        _analysis(
            metrics=[
                {"key": "heartRate", "value": 140, "baseline": 150, "delta": -10,
                 "direction": "better"}
            ]
        )
    )
    assert "hr_efficient" in ids


def test_short_session_suggests_building_duration():
    assert "duration_short" in _ids(_analysis(duration_seconds=600))


def test_low_spo2_is_flagged():
    ids = _ids(_analysis(aggregates={"spo2": {"mean": 95, "min": 88, "max": 99, "n": 50}}))
    assert "spo2_low" in ids


def test_rules_are_deterministic():
    analysis = _analysis()
    assert [i.id for i in evaluate(analysis)] == [i.id for i in evaluate(analysis)]


def test_every_insight_names_a_real_report_section():
    sections = {"what_went_well", "watch_outs", "improve"}
    for analysis in (_analysis(), _analysis(baseline=None), _analysis(data_quality="none")):
        for insight in evaluate(analysis):
            assert insight.section in sections
