"""Nothing extracted reaches a user as a graded result until a clinician has
signed off the catalog.

`biomarkers.v1.yaml` says, in capitals, that its ranges are a v1 draft compiled
from the literature and NOT yet clinically reviewed. Until that review happens
we may show someone the number printed on their report; we may not tell them
what it means. This module is the enforcement of that, and it is the first thing
built in F3 so that everything downstream inherits it.

Two directions matter, and they pull against each other:

**Display is gated.** A perfectly normal HbA1c must come back `ungraded`, not
`optimal`, because "optimal" is a clinical claim sourced from unreviewed content.

**Safety is not gated.** A haemoglobin of 4.1 must escalate immediately anyway.
The clinician queue is for recommendations, never for emergencies — and a
critical bound we are unsure about is still a far better reason to escalate than
silence is.
"""

import textwrap

import pytest

from app.analytics import catalog
from app.analytics.catalog import CatalogError, load_catalog
from app.analytics.reference_ranges import (
    OPTIMAL,
    UNGRADED,
    RangeResolver,
    grade_for_display,
    is_critical,
)


@pytest.fixture(autouse=True)
def _clear_caches():
    """Both caches, in both directions.

    `review_status` is cached separately from the marker set, so clearing only
    one leaves a test grading against the other test's catalog.
    """
    load_catalog.cache_clear()
    catalog.review_status.cache_clear()
    yield
    load_catalog.cache_clear()
    catalog.review_status.cache_clear()


REVIEWED_CATALOG = """
    version: test.v1
    clinical_review:
      reviewed: true
      reviewer: "Dr A. Example, MBBS MD (Endocrinology), reg. 12345"
      reviewed_at: "2026-10-01"
    biomarkers:
      - id: hba1c
        name: HbA1c
        system: metabolic
        canonical_unit: "%"
        units:
          "%": 1.0
        standard: [4.0, 5.6]
        optimal: [4.8, 5.2]
        critical: [3.0, 15.0]
        citation: "ADA Standards of Care"
    """


def use_catalog(tmp_path, monkeypatch, body: str):
    """Point the whole stack at a test catalog.

    The path is monkeypatched rather than threaded through as an argument,
    because the gate must hold on the real production call path — a
    `grade_for_display` that only consults the review status when a test passes
    it one would be no gate at all.
    """
    path = tmp_path / "catalog.yaml"
    path.write_text(textwrap.dedent(body))
    monkeypatch.setattr(catalog, "CATALOG_PATH", path)
    load_catalog.cache_clear()
    catalog.review_status.cache_clear()
    return path


def hba1c_range():
    return RangeResolver().resolve("hba1c", user_id="u1")


# ── The shipped catalog is not reviewed, and says so ─────────────────────────

def test_the_shipped_catalog_is_not_clinically_reviewed():
    """If this ever fails, someone has opened the gate. That should be a PR with
    a clinician's name on it, not a surprise in CI."""
    assert catalog.review_status().reviewed is False


# ── Display is gated ─────────────────────────────────────────────────────────

def test_a_normal_value_is_ungraded_while_the_catalog_is_unreviewed():
    """5.0% is squarely optimal. The user may still not be told that."""
    assert grade_for_display(5.0, hba1c_range()) == UNGRADED


def test_an_abnormal_value_is_also_ungraded():
    """The gate is not "hide the bad news" — it is "make no clinical claim".
    Grading something abnormal is as much a claim as grading it optimal."""
    assert grade_for_display(6.2, hba1c_range()) == UNGRADED


def test_display_grades_normally_once_a_clinician_has_signed_off(tmp_path, monkeypatch):
    use_catalog(tmp_path, monkeypatch, REVIEWED_CATALOG)

    assert grade_for_display(5.0, hba1c_range()) == OPTIMAL


# ── Opening the gate is deliberately hard ────────────────────────────────────

def test_claiming_review_without_a_reviewer_is_refused(tmp_path, monkeypatch):
    """`reviewed: true` is not a thing you can type on the way past. Without a
    named reviewer and a date there is no audit trail, and the whole point of
    keeping medical content in git is that a change has a name attached."""
    with pytest.raises(CatalogError, match="reviewer"):
        use_catalog(
            tmp_path,
            monkeypatch,
            REVIEWED_CATALOG.replace(
                '      reviewer: "Dr A. Example, MBBS MD (Endocrinology), reg. 12345"\n',
                "",
            ),
        )
        catalog.review_status()


def test_claiming_review_without_a_date_is_refused(tmp_path, monkeypatch):
    with pytest.raises(CatalogError, match="reviewed_at|reviewer"):
        use_catalog(
            tmp_path,
            monkeypatch,
            REVIEWED_CATALOG.replace('      reviewed_at: "2026-10-01"\n', ""),
        )
        catalog.review_status()


# ── Safety is never gated ────────────────────────────────────────────────────

def test_a_critical_value_escalates_while_the_catalog_is_unreviewed():
    """The whole reason the gate is not simply "show nothing": a haemoglobin of
    4.1 g/dL needs to escalate today, not after a review meeting."""
    assert is_critical("haemoglobin", 4.1) is True


def test_escalation_does_not_need_to_know_the_persons_sex():
    """Haemoglobin's standard and optimal ranges are sex-specific; its critical
    bounds are not, deliberately.

    This is the hole the obvious implementation leaves. Going through
    `RangeResolver.resolve()` returns None for a sex-specific marker when sex is
    unknown — correct for grading, catastrophic for escalation, because it means
    a haemoglobin of 4.1 silently escalates nothing for every user whose sex we
    do not hold. Escalation therefore reads the catalog's critical bounds
    directly.
    """
    assert RangeResolver().resolve("haemoglobin", user_id="u1", sex=None) is None
    assert is_critical("haemoglobin", 4.1) is True


def test_a_value_inside_critical_bounds_does_not_escalate():
    """False escalation is not harmless. A product that cries emergency at a
    normal haemoglobin trains people to ignore it."""
    assert is_critical("haemoglobin", 14.0) is False


def test_a_censored_result_beyond_a_critical_bound_still_escalates():
    """`>500` on a marker whose critical high is 400 is unknown in magnitude but
    not in direction. It is excluded from biological age, never from safety."""
    assert is_critical("glucose_fasting", 500.0) is True


def test_an_unknown_marker_never_escalates():
    """Silence is right here: we have no bounds, so we have no basis. Escalating
    on a label we failed to map would fire on every unmapped row in a report."""
    assert is_critical("midichlorian_count", 99999.0) is False


def test_a_missing_value_never_escalates():
    """A qualitative result (`Not detected`) has no number to compare."""
    assert is_critical("haemoglobin", None) is False
