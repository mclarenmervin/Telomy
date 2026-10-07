"""The OCR seam.

No engine is chosen yet — that is settled by a bake-off on real reports from the
labs our users actually use, because nobody knows yet whether they send clean
scans (where a light engine is fine) or phone photos (where it falls apart).
This is everything around that decision, so the engine itself is a drop-in.

Two things are worth stating plainly.

**The seam produces exactly what `pdf_text` produces** — `Word`s with bounding
boxes, assembled into a `Document`. Everything downstream is then literally
unchanged: the same scanner reads the columns, the same mapper places the
labels, the same ingest step converts the units.

**The verbatim check gets weaker here and the code says so.** With a text layer
it proves the number is on the page. With OCR it proves the number is in the
*OCR's reading* of the page. It still does its real job — stopping anything
inventing a value — but it no longer proves the number matches the paper. That
is why OCR-derived results are marked, carry lower confidence, and are shown to
the user beside a crop of their own photograph.
"""

import pytest

from app.extraction.ocr import (
    OCR,
    OcrUnavailable,
    UnknownOcrEngine,
    document_from_images,
    get_engine,
    page_from_words,
    rasterise_pdf,
    register_engine,
)
from app.extraction.pdf_text import NONE, Word
from app.extraction.scan import scan_page
from tests.lab_fixtures import lab_report_pdf


class FakeEngine:
    """Stands in for a real engine, returning words with positions.

    Deliberately mimics the geometry of a results table, because the point of
    the seam is that the scanner cannot tell the difference.
    """

    name = "fake"

    def __init__(self, rows=None, calls=None):
        self.rows = rows if rows is not None else [
            ("TEST", 50), ("RESULT", 250), ("UNIT", 330), ("BIOLOGICAL", 410),
        ]
        self.calls = calls if calls is not None else []

    def read_image(self, data):
        self.calls.append(len(data))
        words = []
        for index, (text, x) in enumerate(self.rows):
            top = 100 + (index // 4) * 20
            words.append(Word(text=text, x0=x, x1=x + 40, top=top, bottom=top + 10))
        return words


def table_engine():
    """A header row and one result row, laid out like a real panel."""
    return FakeEngine(rows=[
        ("TEST", 50), ("RESULT", 250), ("UNIT", 330), ("BIOLOGICAL", 410),
        ("HbA1c", 50), ("7.8", 250), ("%", 330), ("4.0", 410),
    ])


# ── Choosing an engine ───────────────────────────────────────────────────────

def test_no_engine_is_configured_by_default():
    """F3a shipped without OCR on purpose, and a build that silently acquired it
    would change what the product promises."""
    assert get_engine(None) is None
    assert get_engine("") is None


def test_an_unknown_engine_name_is_refused_loudly():
    """A typo in OCR_ENGINE must not quietly mean "no OCR" — that would present
    as every photograph failing, with nothing saying why."""
    with pytest.raises(UnknownOcrEngine):
        get_engine("tesseracct")


def test_a_registered_engine_is_returned():
    register_engine("fake", FakeEngine)

    assert get_engine("fake").name == "fake"


# ── Turning words into a page the rest of the pipeline accepts ───────────────

def test_a_page_is_assembled_from_words():
    words = [
        Word(text="HbA1c", x0=50, x1=90, top=100, bottom=110),
        Word(text="7.8", x0=250, x1=270, top=100, bottom=110),
    ]

    page = page_from_words(0, words, width=595, height=842)

    assert page.index == 0
    assert page.words == tuple(words)


def test_the_page_text_contains_every_word_verbatim():
    """The verbatim check compares against this text, so a word missing from it
    would make a perfectly good value unstorable."""
    words = [
        Word(text="HbA1c", x0=50, x1=90, top=100, bottom=110),
        Word(text="7.8", x0=250, x1=270, top=100, bottom=110),
        Word(text="<3.0", x0=250, x1=280, top=130, bottom=140),
    ]

    text = page_from_words(0, words, width=595, height=842).text

    for word in ("HbA1c", "7.8", "<3.0"):
        assert word in text


def test_words_on_one_line_stay_on_one_line():
    """The scanner groups by vertical position, but ingest reads the text, and a
    value split across lines from a label would read as a different row."""
    words = [
        Word(text="HbA1c", x0=50, x1=90, top=100, bottom=110),
        Word(text="7.8", x0=250, x1=270, top=101, bottom=111),
        Word(text="Ferritin", x0=50, x1=95, top=130, bottom=140),
    ]

    lines = page_from_words(0, words, width=595, height=842).text.splitlines()

    assert lines[0] == "HbA1c 7.8"
    assert lines[1] == "Ferritin"


def test_the_scanner_reads_an_ocr_page_exactly_as_it_reads_a_pdf_page():
    """The whole point of the seam. If this holds, the engine is a drop-in."""
    engine = table_engine()
    document = document_from_images([b"fake-image-bytes"], engine)

    candidates = scan_page(document.pages[0])

    assert len(candidates) == 1
    assert candidates[0].label == "HbA1c"
    assert candidates[0].value_text == "7.8"
    assert candidates[0].unit_text == "%"


# ── Documents built from images ──────────────────────────────────────────────

def test_a_document_from_images_is_marked_as_ocr_derived():
    """Recorded on the upload, because it changes how much the result is worth
    trusting and what the confirmation screen has to show."""
    document = document_from_images([b"image"], table_engine())

    assert document.text_layer == OCR


def test_every_image_becomes_its_own_page_numbered_in_order():
    """A photographed three-page panel is three images and one report, and
    `page` has to mean the page the user can look at."""
    engine = table_engine()

    document = document_from_images([b"a", b"bb", b"ccc"], engine)

    assert [page.index for page in document.pages] == [0, 1, 2]
    assert engine.calls == [1, 2, 3]


def test_a_document_with_no_images_reports_no_text_layer():
    assert document_from_images([], table_engine()).text_layer == NONE


def test_an_engine_that_reads_nothing_is_not_mistaken_for_a_text_layer():
    """A blank photograph is a real failure and must not look like a success
    with no values on it."""
    document = document_from_images([b"image"], FakeEngine(rows=[]))

    assert document.text_layer == NONE


def test_an_engine_failure_is_reported_as_unavailable_not_as_an_empty_page():
    class Broken:
        name = "broken"

        def read_image(self, data):
            raise RuntimeError("model weights are missing")

    with pytest.raises(OcrUnavailable):
        document_from_images([b"image"], Broken())


# ── Scanned PDFs ─────────────────────────────────────────────────────────────

def test_a_pdf_can_be_rasterised_for_ocr():
    """A scan is a picture of paper wrapped in a PDF. Rasterising it needs no
    new dependency — pypdfium2 and Pillow already arrive with pdfplumber — so
    the seam covers scanned PDFs as well as photographs."""
    images = rasterise_pdf(lab_report_pdf(pages=2))

    assert len(images) == 2
    # PNG magic number, so this is a real image rather than a passthrough.
    assert all(image.startswith(b"\x89PNG") for image in images)


def test_rasterising_an_unreadable_file_raises_rather_than_returning_nothing():
    from app.extraction.pdf_text import UnreadablePdf

    with pytest.raises(UnreadablePdf):
        rasterise_pdf(b"not a pdf at all")
