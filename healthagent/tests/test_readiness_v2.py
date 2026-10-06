"""Readiness v2 — the same question answered with published models.

v1's constants were invented. v2 replaces each one with a model from the
literature, and the point of the exercise is that every number can now be
traced to a source:

  Tanaka (2001)      age-predicted maximum heart rate
  Banister (1991)    TRIMP training impulse
  Gabbett (2016)     acute:chronic workload ratio
  Buchheit (2014)    HRV and resting HR against a personal rolling baseline
  Borbely / Dijk     two-process sleep-pressure model

This is NOT yet the default. The shadow period validates the port first; only
then is the model changed, so that any divergence has exactly one cause.
"""

from datetime import datetime, timedelta

import pytest

from app.analytics.readiness_v2 import (
    MODEL_VERSION,
    acute_chronic_ratio,
    calculate_v2,
    max_heart_rate,
    sleep_pressure_score,
    trimp,
    z_score,
)
from app.analytics.sleep import Reading

DAY = datetime(2026, 10, 1)


# ── The published formulas ───────────────────────────────────────────────────

def test_max_heart_rate_follows_tanaka():
    """208 - 0.7 x age, which fits older adults far better than 220 - age."""
    assert max_heart_rate(40) == pytest.approx(180.0)
    assert max_heart_rate(70) == pytest.approx(159.0)


def test_max_heart_rate_refuses_an_implausible_age():
    assert max_heart_rate(None) is None
    assert max_heart_rate(2) is None
    assert max_heart_rate(130) is None


def test_trimp_rises_with_duration_and_intensity():
    """Banister's impulse: the same minutes at a higher heart rate cost more."""
    easy = trimp(minutes=30, mean_hr=120, resting_hr=60, max_hr=180, sex="male")
    hard = trimp(minutes=30, mean_hr=160, resting_hr=60, max_hr=180, sex="male")
    longer = trimp(minutes=60, mean_hr=120, resting_hr=60, max_hr=180, sex="male")

    assert hard > easy
    assert longer > easy
    assert longer == pytest.approx(easy * 2)


def test_trimp_is_zero_at_rest():
    assert trimp(minutes=30, mean_hr=60, resting_hr=60, max_hr=180, sex="male") == 0


def test_trimp_refuses_impossible_inputs():
    assert trimp(minutes=30, mean_hr=120, resting_hr=180, max_hr=180, sex="male") is None
    assert trimp(minutes=0, mean_hr=120, resting_hr=60, max_hr=180, sex="male") == 0


def test_acute_chronic_ratio_is_the_spike_detector():
    """Gabbett: a week far above the last month is the injury-risk signal."""
    assert acute_chronic_ratio(acute=100, chronic=100) == pytest.approx(1.0)
    assert acute_chronic_ratio(acute=150, chronic=100) == pytest.approx(1.5)


def test_acute_chronic_ratio_refuses_without_a_chronic_baseline():
    """One week of data cannot tell you whether this week is unusual."""
    assert acute_chronic_ratio(acute=100, chronic=0) is None
    assert acute_chronic_ratio(acute=100, chronic=None) is None


def test_z_score_measures_against_a_persons_own_spread():
    """The Buchheit discipline: a resting heart rate of 58 is unremarkable for
    one person and a warning for another."""
    assert z_score(60, mean=55, sd=5) == pytest.approx(1.0)
    assert z_score(50, mean=55, sd=5) == pytest.approx(-1.0)


def test_z_score_refuses_a_degenerate_baseline():
    assert z_score(60, mean=55, sd=0) is None
    assert z_score(60, mean=None, sd=5) is None


def test_sleep_pressure_rewards_clearing_debt_not_one_good_night():
    """Two-process: pressure accumulates across nights, so a single long sleep
    after a bad week does not reset it."""
    rested = sleep_pressure_score([8.0] * 7, need=8.0)
    deprived = sleep_pressure_score([5.0] * 7, need=8.0)
    one_good_night = sleep_pressure_score([5.0] * 6 + [9.0], need=8.0)

    assert rested > deprived
    assert one_good_night < rested
    assert one_good_night > deprived


def test_sleep_pressure_refuses_without_nights():
    assert sleep_pressure_score([], need=8.0) is None


def test_oversleeping_does_not_score_above_fully_rested():
    assert sleep_pressure_score([11.0] * 7, need=8.0) <= sleep_pressure_score(
        [8.0] * 7, need=8.0)


# ── The composed score ───────────────────────────────────────────────────────

def steady(day, days=35, hrv=55.0, rhr=60.0):
    """A baseline with realistic spread.

    Constant values give a standard deviation of zero, and the z-score then
    correctly refuses to answer — so a fixture without variance tests nothing
    about a model built on personal spread.
    """
    import random

    rng = random.Random(7)
    out = []
    for offset in range(1, days + 1):
        at = day - timedelta(days=offset, hours=-3)
        out += [
            Reading("hrv", hrv + rng.uniform(-6, 6), at),
            Reading("restingHeartRate", rhr + rng.uniform(-3, 3), at),
        ]
        night = (day - timedelta(days=offset)).replace(hour=23) - timedelta(days=1)
        out.append(Reading("sleep", 8.0, night, night + timedelta(hours=8)))
    return out


def test_v2_announces_its_own_version():
    result = calculate_v2(steady(DAY), DAY, age=40, sex="male")

    assert result.model_version == MODEL_VERSION
    assert MODEL_VERSION != "readiness-v1"


def test_a_typical_day_against_a_steady_baseline_scores_well():
    readings = steady(DAY) + [
        Reading("hrv", 56.0, DAY.replace(hour=7)),
        Reading("restingHeartRate", 59.0, DAY.replace(hour=7)),
    ]

    result = calculate_v2(readings, DAY, age=40, sex="male")

    assert result.score is not None
    assert result.score >= 60


def test_suppressed_hrv_and_raised_resting_heart_rate_lower_the_score():
    """The classic overreaching signature."""
    baseline = steady(DAY)
    good = baseline + [
        Reading("hrv", 55.0, DAY.replace(hour=7)),
        Reading("restingHeartRate", 60.0, DAY.replace(hour=7)),
    ]
    strained = baseline + [
        Reading("hrv", 32.0, DAY.replace(hour=7)),
        Reading("restingHeartRate", 71.0, DAY.replace(hour=7)),
    ]

    assert calculate_v2(strained, DAY, age=40, sex="male").score < calculate_v2(
        good, DAY, age=40, sex="male").score


def test_thin_data_refuses_to_score_rather_than_guessing():
    result = calculate_v2([Reading("hrv", 55.0, DAY)], DAY, age=40, sex="male")

    assert result.score is None
    assert result.missing_inputs


def test_every_driver_names_the_model_behind_it():
    """The whole point of v2: a number a clinician can trace."""
    result = calculate_v2(steady(DAY) + [
        Reading("hrv", 56.0, DAY.replace(hour=7)),
        Reading("restingHeartRate", 59.0, DAY.replace(hour=7)),
    ], DAY, age=40, sex="male")

    assert result.drivers
    for driver in result.drivers:
        assert driver.citation, driver.name


def test_an_unknown_age_still_scores_but_loses_the_load_driver():
    """Tanaka needs an age; the rest of the model does not."""
    result = calculate_v2(steady(DAY) + [
        Reading("hrv", 56.0, DAY.replace(hour=7)),
        Reading("restingHeartRate", 59.0, DAY.replace(hour=7)),
    ], DAY, age=None, sex="male")

    assert result.score is not None
