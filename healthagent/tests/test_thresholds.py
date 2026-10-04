import logging

import pytest

from app.common.thresholds import RANGES, Thresholds, describe, get_thresholds

ALL_ENV_KEYS = [name.upper() for name in RANGES]


@pytest.fixture(autouse=True)
def clean_env(monkeypatch):
    """A developer's ambient threshold vars must never change a result."""
    for key in ALL_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)


def _error_records(caplog, env_name):
    return [r for r in caplog.records
            if r.levelname == "ERROR" and env_name in r.getMessage()]


def test_defaults_match_the_reviewed_values(monkeypatch):
    for key in ("SPO2_DANGER_MIN", "SPO2_ATTENTION_MAX", "HEART_RATE_DANGER_MAX",
                "HR_ATTENTION_DELTA", "STRESS_ATTENTION_DELTA", "HRV_ATTENTION_DELTA"):
        monkeypatch.delenv(key, raising=False)

    t = get_thresholds()

    assert t.spo2_danger_min == 90.0
    assert t.spo2_attention_max == 95.0
    assert t.heart_rate_danger_max == 200.0
    assert t.hr_attention_delta == 15.0
    assert t.stress_attention_delta == 15.0
    assert t.hrv_attention_delta == 15.0


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
    assert _error_records(caplog, "SPO2_DANGER_MIN")


def test_out_of_range_value_falls_back_and_logs(monkeypatch, caplog):
    """0 would silently disable the urgent SpO2 warning — the worst failure here."""
    monkeypatch.setenv("SPO2_DANGER_MIN", "0")

    with caplog.at_level(logging.ERROR):
        t = get_thresholds()

    assert t.spo2_danger_min == 90.0
    assert "SPO2_DANGER_MIN" in caplog.text
    assert _error_records(caplog, "SPO2_DANGER_MIN")


def test_describe_lists_every_effective_value():
    """Logged once at worker start so a running deployment can be audited."""
    text = describe(Thresholds())

    for key in ("spo2_danger_min", "heart_rate_danger_max", "hr_attention_delta"):
        assert key in text


# Pinned independently of RANGES so an edit to the table cannot also edit the
# expectation: a narrowed or mistyped bound must fail here.
EXPECTED_BOUNDS = [
    ("spo2_danger_min", 85.0, 99.0, 90.0),
    ("spo2_attention_max", 85.0, 99.0, 95.0),
    ("heart_rate_danger_max", 150.0, 230.0, 200.0),
    ("hr_attention_delta", 5.0, 50.0, 15.0),
    ("stress_attention_delta", 5.0, 50.0, 15.0),
    ("hrv_attention_delta", 5.0, 50.0, 15.0),
    ("check_in_hr_delta", 5.0, 50.0, 12.0),
    ("check_in_hr_z", 1.0, 6.0, 2.0),
    ("check_in_hrv_drop_pct", 10.0, 60.0, 25.0),
    ("check_in_min_elapsed_seconds", 0.0, 7200.0, 900.0),
]


def test_range_table_covers_exactly_the_expected_fields():
    assert {n for n, *_ in EXPECTED_BOUNDS} == set(RANGES) == set(Thresholds.__dataclass_fields__)


@pytest.mark.parametrize("name,low,high,default", EXPECTED_BOUNDS)
def test_both_bounds_are_accepted(monkeypatch, caplog, name, low, high, default):
    for bound in (low, high):
        monkeypatch.setenv(name.upper(), str(bound))
        with caplog.at_level(logging.ERROR):
            t = get_thresholds()
        assert getattr(t, name) == bound
    assert not _error_records(caplog, name.upper())


@pytest.mark.parametrize("name,low,high,default", EXPECTED_BOUNDS)
@pytest.mark.parametrize("side", ["below", "above"])
def test_just_outside_a_bound_is_rejected_and_logged(
    monkeypatch, caplog, name, low, high, default, side
):
    bad = low - 1 if side == "below" else high + 1
    monkeypatch.setenv(name.upper(), str(bad))

    with caplog.at_level(logging.ERROR):
        t = get_thresholds()

    assert getattr(t, name) == default
    assert _error_records(caplog, name.upper())


@pytest.mark.parametrize("value", ["85", "99", "5", "50", "150", "230"])
def test_boundary_values_are_accepted_on_their_fields(monkeypatch, value):
    """The spec's named edge values; each belongs to at least one field."""
    accepted = [n for n, lo, hi, _ in EXPECTED_BOUNDS if lo <= float(value) <= hi]
    assert accepted
    for name in accepted:
        monkeypatch.setenv(name.upper(), value)
        assert getattr(get_thresholds(), name) == float(value)
        monkeypatch.delenv(name.upper())


def test_check_in_defaults_are_strict():
    thresholds = get_thresholds()

    assert thresholds.check_in_hr_delta == 12.0
    assert thresholds.check_in_hr_z == 2.0
    assert thresholds.check_in_hrv_drop_pct == 25.0
    assert thresholds.check_in_min_elapsed_seconds == 900.0


def test_check_in_threshold_outside_its_range_falls_back_to_the_default(monkeypatch):
    monkeypatch.setenv("CHECK_IN_HR_Z", "0.1")

    assert get_thresholds().check_in_hr_z == 2.0


def test_check_in_threshold_is_overridable_within_range(monkeypatch):
    monkeypatch.setenv("CHECK_IN_HR_DELTA", "20")

    assert get_thresholds().check_in_hr_delta == 20.0
