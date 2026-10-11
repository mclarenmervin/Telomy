"""The inference primitives, checked against values from published tables.

These are the only place in the product where a p-value is produced, so they
are pinned against figures a reader can look up rather than against whatever
the implementation happened to return the first time.
"""

import math

import pytest

from app.analytics.statistics import (
    benjamini_hochberg,
    effective_sample_size,
    lag1_autocorrelation,
    one_sample_t,
    pearson,
    pearson_p_value,
    student_t_two_tailed,
)


# ── Pearson ──────────────────────────────────────────────────────────────────

def test_a_perfect_straight_line_is_one():
    assert pearson([1, 2, 3, 4], [2, 4, 6, 8]) == pytest.approx(1.0)


def test_a_perfect_inverse_is_minus_one():
    assert pearson([1, 2, 3, 4], [8, 6, 4, 2]) == pytest.approx(-1.0)


def test_a_flat_series_has_no_coefficient_rather_than_zero():
    """Zero would read as "these are unrelated". Nothing can be said about a
    series that never moved, which is a different answer."""
    assert pearson([1, 2, 3], [5, 5, 5]) is None


def test_too_few_points_has_no_coefficient():
    assert pearson([1], [2]) is None


# ── The t distribution ───────────────────────────────────────────────────────

def test_zero_t_is_certainly_not_significant():
    assert student_t_two_tailed(0.0, 10) == pytest.approx(1.0)


def test_the_five_percent_critical_value_at_ten_degrees_of_freedom():
    """t(0.025, 10) = 2.228 in every published table."""
    assert student_t_two_tailed(2.228, 10) == pytest.approx(0.05, abs=1e-4)


def test_one_degree_of_freedom_is_cauchy():
    """With df=1 the t distribution is standard Cauchy, and P(|T| > 1) is
    exactly one half — an identity, so it pins the tail with no table."""
    assert student_t_two_tailed(1.0, 1) == pytest.approx(0.5, abs=1e-9)


def test_a_large_df_approaches_the_normal():
    """1.959964 is the two-sided 5% point of the standard normal."""
    assert student_t_two_tailed(1.959964, 2_000_000) == pytest.approx(0.05, abs=1e-4)


def test_the_tail_is_symmetric():
    assert student_t_two_tailed(-2.5, 7) == pytest.approx(student_t_two_tailed(2.5, 7))


# ── r to p ───────────────────────────────────────────────────────────────────

def test_the_critical_correlation_at_twenty_pairs():
    """r = 0.4438 is the 5% two-tailed critical value for n = 20 (df = 18)."""
    assert pearson_p_value(0.4438, 20) == pytest.approx(0.05, abs=1e-3)


def test_a_perfect_correlation_cannot_divide_by_zero():
    """r = 1 makes the t statistic infinite. It is the most significant thing
    possible, not a crash."""
    assert pearson_p_value(1.0, 10) == 0.0


def test_fewer_than_three_pairs_has_no_p_value():
    """Two points are always perfectly correlated, so there is no evidence in
    them at all."""
    assert pearson_p_value(0.99, 2) is None


# ── Autocorrelation and the effective sample size ────────────────────────────

def test_an_alternating_series_is_negatively_autocorrelated():
    assert lag1_autocorrelation([1, -1, 1, -1, 1, -1]) < -0.5


def test_a_rising_series_is_positively_autocorrelated():
    assert lag1_autocorrelation([1, 2, 3, 4, 5, 6, 7, 8]) > 0.5


def test_independent_series_keep_their_whole_sample_size():
    assert effective_sample_size(90, 0.0, 0.0) == pytest.approx(90)


def test_two_autocorrelated_series_are_worth_far_fewer_days():
    """Both at 0.5: (1 - 0.25) / (1 + 0.25) = 0.6, so 90 days carry the
    evidence of 54."""
    assert effective_sample_size(90, 0.5, 0.5) == pytest.approx(54)


def test_two_anti_persistent_series_are_also_worth_fewer_days():
    """Both negative multiplies to a positive, so the adjustment bites the
    same way it does for two persistent series."""
    assert effective_sample_size(30, -0.8, -0.8) < 30


def test_the_effective_size_never_exceeds_the_real_one():
    """Autocorrelations of opposite sign multiply to a negative and the
    formula then claims 136 independent samples from 30 days. We do not take
    the credit."""
    assert effective_sample_size(30, 0.8, -0.8) == 30


def test_the_effective_size_never_falls_below_three():
    """Below three there is no p-value to compute, and the caller needs a
    number it can reason about rather than a zero."""
    assert effective_sample_size(50, 0.99, 0.99) >= 3


# ── Benjamini-Hochberg ───────────────────────────────────────────────────────

def test_nothing_survives_when_nothing_is_small():
    assert benjamini_hochberg([0.4, 0.5, 0.9], 0.05) == [False, False, False]


def test_the_textbook_ladder():
    """p = .01 .. .05 against i*q/m with q = .05 and m = 5: every rung is met,
    so all five survive."""
    assert benjamini_hochberg([0.01, 0.02, 0.03, 0.04, 0.05], 0.05) == [True] * 5


def test_a_single_small_p_among_many_large_ones_does_not_survive():
    """The whole point of the correction. 0.01 looks significant alone and is
    exactly what you expect once in a hundred tries."""
    kept = benjamini_hochberg([0.01] + [0.6] * 99, 0.05)
    assert kept[0] is False


def test_the_step_up_keeps_a_larger_p_below_a_surviving_one():
    """BH is step-UP: once the largest surviving rung is found, everything
    smaller survives too, even where its own rung is not met."""
    kept = benjamini_hochberg([0.001, 0.049], 0.05)
    assert kept == [True, True]


def test_order_is_preserved_rather_than_sorted():
    kept = benjamini_hochberg([0.9, 0.001], 0.05)
    assert kept == [False, True]


def test_an_empty_run_rejects_nothing_rather_than_failing():
    assert benjamini_hochberg([], 0.05) == []


# ── One sample, for a before/after delta ─────────────────────────────────────

def test_a_set_of_deltas_centred_on_zero_is_not_a_change():
    assert one_sample_t([-2.0, 1.0, -1.0, 2.0, 0.0])[1] > 0.5


def test_a_consistent_shift_is_a_change():
    mean, p = one_sample_t([4.0, 5.0, 3.5, 4.5, 5.5, 4.0, 3.0, 5.0])
    assert mean == pytest.approx(4.3125)
    assert p < 0.001


def test_the_textbook_one_sample_t():
    """Five values, mean 2, sample sd 1.5811, so t = 2/(1.5811/sqrt(5)) =
    2.828 on 4 df, which is p = 0.0474 in any table."""
    mean, p = one_sample_t([0.0, 1.0, 2.0, 3.0, 4.0])
    assert mean == pytest.approx(2.0)
    assert p == pytest.approx(0.0474, abs=5e-4)


def test_one_observation_is_not_evidence():
    assert one_sample_t([3.0]) == (3.0, None)


def test_nothing_at_all_has_no_mean_and_no_p():
    assert one_sample_t([]) == (None, None)


def test_identical_deltas_are_a_certain_change_rather_than_a_crash():
    """Zero variance makes the t statistic infinite. Eight sessions that each
    moved the needle by exactly 4 is the most certain thing there is, not a
    division by zero."""
    mean, p = one_sample_t([4.0] * 8)
    assert mean == 4.0
    assert p == 0.0


def test_identical_deltas_of_zero_are_no_change_at_all():
    assert one_sample_t([0.0] * 8) == (0.0, 1.0)
