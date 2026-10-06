"""Finding results on a page, deterministically.

No LLM runs here and none ever will. This module decides what the numbers on a
page are; the LLM is only ever asked which marker a *label* names (P2). Every
value it produces is a span lifted verbatim out of the page text, which is what
makes the verbatim assertion downstream meaningful rather than circular.

The misread this exists to prevent:

    Glucose, Fasting      142      mg/dL     70 - 100

"the first number after the label" is 142 here and 70 on a report that prints
the reference interval first. Both layouts are real. The scanner resolves it by
column geometry: results share an x-position down the page, and so do reference
intervals.
"""

import pytest

from app.extraction.pdf_text import read_pdf
from app.extraction.scan import QUALITATIVE, QUANTITATIVE, scan_page
from tests.lab_fixtures import (
    DEFAULT_ROWS,
    flagged_rows,
    lab_report_pdf,
    reference_first_pdf,
)


def scan_default(**kwargs):
    document = read_pdf(lab_report_pdf(**kwargs))
    return scan_page(document.pages[0])


def by_label(candidates, fragment):
    matches = [c for c in candidates if fragment.lower() in c.label.lower()]
    assert matches, f"no candidate whose label contains {fragment!r}"
    return matches[0]


# ── The reference-range column ───────────────────────────────────────────────

def test_the_result_is_taken_and_not_the_reference_interval():
    """The single most dangerous misread available. 70 is the bottom of the
    normal range; reporting it as the result turns a diabetic fasting glucose
    into a healthy one."""
    assert by_label(scan_default(), "Glucose, Fasting").value_text == "142"


def test_the_reference_interval_is_captured_separately_not_discarded():
    """Kept because the confirmation screen shows the user what the lab printed
    beside their result, and because a wildly different range is a signal the
    column detection went wrong."""
    assert by_label(scan_default(), "Glucose, Fasting").reference_text == "70 - 100"


def test_every_row_of_the_panel_is_found():
    labels = {c.label for c in scan_default()}

    for printed_name, _, _, _ in DEFAULT_ROWS:
        assert any(printed_name.lower() in label.lower() for label in labels), printed_name


# ── The footer, and other numbers that are not results ───────────────────────

def test_the_footer_phone_number_is_not_read_as_a_result():
    """`Customer Care : 011 - 4988 5050` sits in the test-name column and is
    exactly what a "label followed by a number" heuristic picks up."""
    values = {c.value_text for c in scan_default()}

    for noise in ("011", "4988", "5050", "25531"):
        assert noise not in values, f"{noise} came from the footer"


def test_the_page_number_is_not_read_as_a_result():
    labels = " ".join(c.label for c in scan_default()).lower()

    assert "page" not in labels


def test_the_lab_number_in_the_header_is_not_read_as_a_result():
    values = {c.value_text for c in scan_default()}

    assert "0458871923" not in values


# ── Values that are not plain numbers ────────────────────────────────────────

def test_a_censored_result_keeps_its_operator():
    """`<3.0` is routine on a vitamin D panel and crashes a float() parse on day
    one. The operator is kept because the value may be displayed and may
    escalate, but must be excluded from biological age and correlations."""
    candidate = by_label(scan_default(), "Vitamin D")

    assert candidate.operator == "<"
    assert candidate.value_text == "3.0"
    assert candidate.result_type == QUANTITATIVE


def test_a_qualitative_result_is_never_coerced_to_a_number():
    candidate = by_label(scan_default(), "Dengue")

    assert candidate.result_type == QUALITATIVE
    assert candidate.value_text == "Negative"


def test_a_qualitative_result_carries_no_operator():
    assert by_label(scan_default(), "Dengue").operator == "="


# ── Units ────────────────────────────────────────────────────────────────────

def test_the_unit_is_read_from_its_own_column():
    assert by_label(scan_default(), "HbA1c").unit_text == "%"
    assert by_label(scan_default(), "Haemoglobin").unit_text == "g/dL"


def test_a_row_with_no_unit_reports_none_rather_than_guessing():
    assert by_label(scan_default(), "Dengue").unit_text in (None, "")


# ── Provenance ───────────────────────────────────────────────────────────────

def test_every_candidate_carries_the_page_it_came_from():
    assert all(c.page == 0 for c in scan_default())


def test_every_candidate_carries_a_bounding_box():
    """Stored on the row, and what lets the confirmation screen show the user
    the part of the report a number was read from."""
    box = by_label(scan_default(), "HbA1c").bbox

    assert set(box) == {"x0", "x1", "top", "bottom"}
    assert box["x1"] > box["x0"]


def test_every_value_appears_verbatim_in_the_page_text():
    """The property the whole P2 argument rests on. If the scanner ever
    *computed* a value rather than lifting a span, this fails."""
    document = read_pdf(lab_report_pdf())
    text = document.pages[0].text

    for candidate in scan_page(document.pages[0]):
        assert candidate.value_text in text, candidate


# ── Layouts that differ ──────────────────────────────────────────────────────

def test_a_marker_appearing_twice_yields_two_candidates():
    """Fasting and post-prandial glucose from one draw. Keyed later by context,
    but the scanner must not collapse them here."""
    glucose = [c for c in scan_default() if "glucose" in c.label.lower()]

    assert sorted(c.value_text for c in glucose) == ["142", "198"]


def test_a_page_with_no_table_yields_nothing_rather_than_guessing():
    document = read_pdf(lab_report_pdf(rows=[]))

    assert scan_page(document.pages[0]) == []


def test_the_result_is_found_when_the_reference_interval_comes_first():
    """The test that makes the column detection load bearing.

    Every other fixture prints the result before the interval, so a scanner
    doing nothing cleverer than "the first number after the label" passes all of
    them. On this layout that scanner returns 70 for a fasting glucose of 142 —
    and 70 is a perfectly plausible glucose, so nothing downstream would catch
    it. Both layouts ship.
    """
    document = read_pdf(reference_first_pdf())
    candidates = scan_page(document.pages[0])

    glucose = by_label(candidates, "Glucose, Fasting")
    assert glucose.value_text == "142"
    assert glucose.reference_text == "70 - 100"
    assert glucose.unit_text == "mg/dL"


def test_the_whole_panel_survives_a_reordered_layout():
    document = read_pdf(reference_first_pdf())

    found = {c.label: c.value_text for c in scan_page(document.pages[0])}

    assert found["HbA1c"] == "7.8"
    assert found["Haemoglobin"] == "13.2"
    assert found["Dengue NS1 Antigen"] == "Negative"


# ── The lab's own flags ──────────────────────────────────────────────────────

def test_an_out_of_range_flag_is_not_read_as_part_of_the_value():
    """Most reports print `142 H`. The flag belongs to the cell, not the value,
    and `142 H` must not fail to parse as a number."""
    document = read_pdf(lab_report_pdf(rows=flagged_rows()))
    candidates = scan_page(document.pages[0])

    assert by_label(candidates, "Glucose, Fasting").value_text == "142"
    assert by_label(candidates, "Haemoglobin").value_text == "10.1"


def test_a_flag_does_not_become_a_qualitative_result():
    document = read_pdf(lab_report_pdf(rows=flagged_rows()))

    assert all(c.result_type == QUANTITATIVE for c in scan_page(document.pages[0]))


def test_scanning_is_pure_and_repeatable():
    """Deterministic means deterministic: same page, same answer, always."""
    document = read_pdf(lab_report_pdf())

    first = scan_page(document.pages[0])
    second = scan_page(document.pages[0])

    assert first == second
