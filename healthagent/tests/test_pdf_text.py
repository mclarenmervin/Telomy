"""Getting words and their positions out of a lab PDF.

This layer does no interpretation. Its whole job is to hand the scanner words
with coordinates, because position is what distinguishes a result from the
reference interval printed beside it — and a text extractor that returns a
flat string has already thrown that away.

It also has to name its failures precisely. "Extraction failed" is useless to a
user holding a password-protected report, which is standard practice for Indian
labs; they need to be asked for the password and allowed to retry.
"""

import pytest

from app.extraction.pdf_text import (
    NATIVE,
    NONE,
    PasswordRequired,
    UnreadablePdf,
    read_pdf,
)
from tests.lab_fixtures import image_only_pdf, lab_report_pdf


def test_a_report_yields_pages_of_positioned_words():
    document = read_pdf(lab_report_pdf())

    assert len(document.pages) == 1
    words = document.pages[0].words
    assert len(words) > 50
    assert all(w.x1 > w.x0 for w in words)


def test_the_text_layer_is_reported_as_native():
    assert read_pdf(lab_report_pdf()).text_layer == NATIVE


def test_every_printed_value_appears_verbatim_in_the_page_text():
    """The check that keeps the LLM out of arithmetic depends on this. If the
    page text did not contain the number as printed, the verbatim assertion
    downstream would be comparing against something we invented."""
    text = read_pdf(lab_report_pdf()).pages[0].text

    for printed in ("142", "198", "7.8", "13.2", "<3.0", "60", "Negative"):
        assert printed in text, f"{printed!r} is not in the page text"


def test_words_carry_the_geometry_the_scanner_needs():
    """Column position is the whole mechanism for telling 142 from 70."""
    words = read_pdf(lab_report_pdf()).pages[0].words

    result_column = [w for w in words if 245 < w.x0 < 255]
    reference_column = [w for w in words if 405 < w.x0 < 415]

    assert "142" in [w.text for w in result_column]
    assert "70" in [w.text for w in reference_column]
    assert "142" not in [w.text for w in reference_column]


def test_pages_are_numbered_from_zero():
    """The index is what biomarker_results.page refers to, and what the
    confirmation UI uses to show the user where a value came from."""
    document = read_pdf(lab_report_pdf(pages=3))

    assert [page.index for page in document.pages] == [0, 1, 2]


# ── Password-protected reports ───────────────────────────────────────────────

def test_an_encrypted_report_without_a_password_asks_for_one():
    """Not a failure. Indian labs routinely send password-protected PDFs, often
    with the date of birth as the password, and the flow needs a prompt and a
    retry rather than a dead end."""
    with pytest.raises(PasswordRequired):
        read_pdf(lab_report_pdf(password="01011972"))


def test_an_encrypted_report_opens_with_the_right_password():
    document = read_pdf(lab_report_pdf(password="01011972"), password="01011972")

    assert "142" in document.pages[0].text


def test_the_wrong_password_asks_again_rather_than_failing():
    with pytest.raises(PasswordRequired):
        read_pdf(lab_report_pdf(password="01011972"), password="wrong")


# ── Documents we cannot read from the text layer ─────────────────────────────

def test_a_scan_with_no_text_layer_is_reported_not_raised():
    """A photographed report is the common case, not an error. It is recorded as
    having no text layer so the upload can be routed to OCR, and so that an
    OCR-derived result can be forced through confirmation later."""
    document = read_pdf(image_only_pdf())

    assert document.text_layer == NONE
    assert document.pages[0].words == ()


def test_a_file_that_is_not_a_pdf_is_a_named_failure():
    """Uploaded files are untrusted. A corrupt or mislabelled one must fail by
    name, not as whatever pdfminer happens to raise."""
    with pytest.raises(UnreadablePdf):
        read_pdf(b"this is not a pdf, it is a sentence")


def test_an_empty_file_is_a_named_failure():
    with pytest.raises(UnreadablePdf):
        read_pdf(b"")
