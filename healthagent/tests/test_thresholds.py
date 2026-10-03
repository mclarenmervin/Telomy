import logging

from app.common.thresholds import Thresholds, describe, get_thresholds


def test_defaults_match_the_reviewed_values(monkeypatch):
    for key in ("SPO2_DANGER_MIN", "SPO2_ATTENTION_MAX", "HEART_RATE_DANGER_MAX",
                "HR_ATTENTION_DELTA", "STRESS_ATTENTION_DELTA", "HRV_ATTENTION_DELTA"):
        monkeypatch.delenv(key, raising=False)

    t = get_thresholds()

    assert t.spo2_danger_min == 90.0
    assert t.spo2_attention_max == 95.0
    assert t.heart_rate_danger_max == 200.0
    assert t.hr_attention_delta == 15.0


def test_env_overrides_a_threshold(monkeypatch):
    monkeypatch.setenv("SPO2_ATTENTION_MAX", "94")

    assert get_thresholds().spo2_attention_max == 94.0


def test_non_numeric_value_falls_back_and_logs(monkeypatch, caplog):
    """A typo must not crash the worker on startup."""
    monkeypatch.setenv("SPO2_DANGER_MIN", "abc")

    with caplog.at_level(logging.ERROR):
        t = get_thresholds()

    assert t.spo2_danger_min == 90.0
    assert "SPO2_DANGER_MIN" in caplog.text


def test_out_of_range_value_falls_back_and_logs(monkeypatch, caplog):
    """0 would silently disable the urgent SpO2 warning — the worst failure here."""
    monkeypatch.setenv("SPO2_DANGER_MIN", "0")

    with caplog.at_level(logging.ERROR):
        t = get_thresholds()

    assert t.spo2_danger_min == 90.0
    assert "SPO2_DANGER_MIN" in caplog.text


def test_describe_lists_every_effective_value():
    """Logged once at worker start so a running deployment can be audited."""
    text = describe(Thresholds())

    for key in ("spo2_danger_min", "heart_rate_danger_max", "hr_attention_delta"):
        assert key in text
