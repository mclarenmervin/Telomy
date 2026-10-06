"""Resolving which range applies, and grading a value against it.

Two properties matter more than the arithmetic:

1. Resolution order is user -> clinic -> global, decided in exactly one place.
2. A result already shown to someone cannot change meaning later. Ranges are
   versioned and immutable; a clinician override appends a new set.
"""

import pytest

from app.analytics.reference_ranges import (
    ABNORMAL,
    CRITICAL,
    NORMAL,
    OPTIMAL,
    UNGRADED,
    RangeResolver,
    grade,
)


class FakeOverrides:
    """Stands in for the clinic/user override tables.

    Returns every override the user has in one call — grading a panel must not
    be one round trip per marker.
    """

    def __init__(self, rows=()):
        self.rows = list(rows)
        self.calls = 0

    def __call__(self, user_id):
        self.calls += 1
        return list(self.rows)


def override(scope, biomarker_id="hba1c", standard=(4.0, 6.5), optimal=(4.8, 5.4),
             version="clinic.v3", citation="Clinic protocol 2026"):
    return {
        "scope": scope,
        "biomarker_id": biomarker_id,
        "standard_low": standard[0], "standard_high": standard[1],
        "optimal_low": optimal[0], "optimal_high": optimal[1],
        "version": version,
        "citation": citation,
    }


# ── Resolution ───────────────────────────────────────────────────────────────

def test_the_global_catalog_applies_when_there_is_no_override():
    resolved = RangeResolver(FakeOverrides()).resolve("hba1c", user_id="u1")

    assert resolved.standard.high == 5.6
    assert resolved.optimal.high == 5.2
    assert resolved.version == "global.v1"
    assert resolved.scope == "global"


def test_a_clinic_override_beats_the_global_catalog():
    resolver = RangeResolver(FakeOverrides([override("clinic")]))

    resolved = resolver.resolve("hba1c", user_id="u1")

    assert resolved.standard.high == 6.5
    assert resolved.scope == "clinic"
    assert resolved.version == "clinic.v3"


def test_a_user_override_beats_a_clinic_override():
    resolver = RangeResolver(FakeOverrides([
        override("clinic", version="clinic.v3"),
        override("user", standard=(4.0, 7.0), version="user.v1"),
    ]))

    resolved = resolver.resolve("hba1c", user_id="u1")

    assert resolved.scope == "user"
    assert resolved.standard.high == 7.0


def test_an_override_for_a_different_marker_does_not_apply():
    resolver = RangeResolver(FakeOverrides([override("clinic", biomarker_id="ldl_cholesterol")]))

    resolved = resolver.resolve("hba1c", user_id="u1")

    assert resolved.scope == "global"


def test_critical_bounds_are_never_overridable():
    """A clinic may widen what counts as normal. It may not switch off the
    threshold at which we tell someone to seek care."""
    resolver = RangeResolver(FakeOverrides([override("clinic", standard=(0.0, 99.0))]))

    resolved = resolver.resolve("hba1c", user_id="u1")

    assert resolved.critical.high == 15.0


def test_a_sex_specific_marker_resolves_per_sex():
    resolver = RangeResolver(FakeOverrides())

    male = resolver.resolve("ferritin", user_id="u1", sex="male")
    female = resolver.resolve("ferritin", user_id="u1", sex="female")

    assert male.standard.low == 30
    assert female.standard.low == 15


def test_a_sex_specific_marker_without_a_sex_resolves_to_nothing():
    resolved = RangeResolver(FakeOverrides()).resolve("ferritin", user_id="u1")

    assert resolved is None


def test_an_unknown_marker_resolves_to_nothing():
    assert RangeResolver(FakeOverrides()).resolve("midichlorians", user_id="u1") is None


def test_overrides_are_read_once_per_user_not_once_per_marker():
    """Grading a 40-marker panel must not be 40 round trips."""
    overrides = FakeOverrides()
    resolver = RangeResolver(overrides)

    for marker in ("hba1c", "ldl_cholesterol", "hs_crp", "tsh"):
        resolver.resolve(marker, user_id="u1")

    assert overrides.calls == 1


# ── Grading ──────────────────────────────────────────────────────────────────

@pytest.fixture
def hba1c():
    return RangeResolver(FakeOverrides()).resolve("hba1c", user_id="u1")


def test_a_value_inside_optimal_is_optimal(hba1c):
    assert grade(5.0, hba1c) == OPTIMAL


def test_a_value_inside_standard_but_outside_optimal_is_normal(hba1c):
    """The distinction the whole feature exists for: statistically unremarkable
    is not the same as well."""
    assert grade(5.5, hba1c) == NORMAL


def test_a_value_outside_standard_is_abnormal(hba1c):
    assert grade(6.2, hba1c) == ABNORMAL


def test_a_value_outside_critical_is_critical(hba1c):
    assert grade(16.0, hba1c) == CRITICAL


def test_grading_without_a_resolved_range_is_ungraded_not_normal(hba1c):
    """Absence of a range must never read as a clean result."""
    assert grade(5.0, None) == UNGRADED


def test_grading_a_missing_value_is_ungraded(hba1c):
    assert grade(None, hba1c) == UNGRADED


def test_boundaries_are_inclusive(hba1c):
    assert grade(4.8, hba1c) == OPTIMAL
    assert grade(5.2, hba1c) == OPTIMAL
    assert grade(5.6, hba1c) == NORMAL
