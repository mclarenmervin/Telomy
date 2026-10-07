"""Reading a photographed or scanned report.

The engine is not chosen here, and deliberately not yet: that is settled by a
bake-off on real reports from the labs our users actually use, because nobody
knows yet whether they send clean scans — where a light engine is adequate — or
phone photos, where it falls apart and the column structure is lost. This module
is everything around that decision, so the engine itself is a drop-in.

**The seam produces exactly what `pdf_text` produces**: `Word`s with bounding
boxes, assembled into a `Document`. Everything downstream is then literally
unchanged — the same scanner reads the columns by geometry, the same mapper
places the labels, the same ingest step converts the units and runs the verbatim
check. A test asserts the scanner cannot tell an OCR page from a PDF page.

**The verbatim check is weaker here, and that is not something to paper over.**
With a text layer it proves the number is on the page. With OCR it proves the
number is in the OCR's *reading* of the page. It still does its real job —
nothing can invent a value — but it no longer proves the number matches the
paper. OCR misreads digits, and `14` read as `1.4` is a plausible haemoglobin.

That is why an OCR-derived result is marked as such, carries lower confidence,
and is shown to the user beside a crop of their own photograph. The crop is the
check that replaces the one we lost: the user compares our number against the
picture, not against their memory.
"""

import io
from dataclasses import dataclass
from typing import Callable, Protocol

from app.common.logging_config import get_logger
from app.extraction.pdf_text import NONE, OCR, Document, Page, UnreadablePdf, Word

logger = get_logger(__name__)

# Words within this many points of each other vertically are on one line, the
# same tolerance the scanner uses.
_LINE_TOLERANCE = 3.0

# Enough detail for small print without making every page a multi-megabyte
# bitmap. Lab reports are typically 8pt type.
RASTERISE_DPI = 200


class OcrUnavailable(Exception):
    """The engine could not read this image.

    Distinct from "there was nothing to read": a missing model or a crashed
    engine must fail the upload with a reason, not present as a blank page.
    """


class UnknownOcrEngine(ValueError):
    """`OCR_ENGINE` names something this build does not have.

    Raised rather than treated as "no OCR", because a typo would otherwise
    present as every photograph failing with nothing saying why.
    """


class OcrEngine(Protocol):
    """What an engine has to provide. Words, with where they are.

    Position is not optional. Without boxes the scanner cannot tell a result
    from the reference interval printed beside it, which is the misread that
    turns a diabetic glucose into a healthy one.
    """

    name: str

    def read_image(self, data: bytes) -> list[Word]:
        ...


_ENGINES: dict[str, Callable[[], OcrEngine]] = {}


def register_engine(name: str, factory: Callable[[], OcrEngine]) -> None:
    """Make an engine available under a name. Called by the engine modules
    themselves, and by tests."""
    _ENGINES[name] = factory


def get_engine(name: str | None) -> OcrEngine | None:
    """The configured engine, or None when OCR is switched off.

    None is the default and a real state: F3a ships without OCR, and a build
    that silently acquired it would change what the product promises.
    """
    if not name:
        return None
    factory = _ENGINES.get(name)
    if factory is None:
        raise UnknownOcrEngine(
            f"no OCR engine named {name!r}; available: {sorted(_ENGINES) or 'none'}"
        )
    return factory()


def _text_from(words) -> str:
    """The page's text, laid out in lines.

    Reconstructed rather than concatenated, because ingest's verbatim check and
    the date scanner both read this text, and the date scanner is bounded to the
    label's own *line* — a flat string would put every date on one line and let
    the report date stand in for the collection date.
    """
    lines: list[list[Word]] = []
    for word in sorted(words, key=lambda w: (w.top, w.x0)):
        if lines and abs(lines[-1][0].top - word.top) <= _LINE_TOLERANCE:
            lines[-1].append(word)
        else:
            lines.append([word])
    return "\n".join(
        " ".join(w.text for w in sorted(line, key=lambda w: w.x0)) for line in lines
    )


def page_from_words(index: int, words, width: float, height: float) -> Page:
    """One page, in the shape the rest of the pipeline already consumes."""
    ordered = tuple(words)
    return Page(
        index=index,
        words=ordered,
        text=_text_from(ordered),
        width=width,
        height=height,
    )


def document_from_images(images, engine: OcrEngine) -> Document:
    """Every image read as its own page, numbered in order.

    A photographed three-page panel is three images and one report, and `page`
    has to mean the page the user can actually look at.
    """
    pages: list[Page] = []
    for index, data in enumerate(images):
        try:
            words = engine.read_image(data)
        except Exception as error:
            raise OcrUnavailable(
                f"{engine.name} could not read page {index}: {error}"
            ) from error
        width, height = _extent(words)
        pages.append(page_from_words(index, words, width=width, height=height))

    # No words anywhere is a real failure — a blank or unreadable photograph —
    # and must not look like a success that happened to find nothing.
    has_words = any(page.words for page in pages)
    return Document(pages=tuple(pages), text_layer=OCR if has_words else NONE)


def _extent(words) -> tuple[float, float]:
    """The page's size, inferred from what was found on it.

    Engines report pixel coordinates and not all of them report the canvas, but
    nothing downstream needs more than a bound: the scanner works in relative
    positions and only the stored bbox is absolute.
    """
    if not words:
        return 0.0, 0.0
    return max(w.x1 for w in words), max(w.bottom for w in words)


def rasterise_pdf(data: bytes, dpi: int = RASTERISE_DPI) -> list[bytes]:
    """A PDF's pages as PNG images, for OCR.

    A scan is a picture of paper wrapped in a PDF, so it needs the same
    treatment as a photograph. This costs no new dependency: pypdfium2 and
    Pillow both arrive with pdfplumber already.
    """
    try:
        import pypdfium2
    except ImportError as error:  # pragma: no cover - ships with pdfplumber
        raise OcrUnavailable("rasterising needs pypdfium2") from error

    try:
        document = pypdfium2.PdfDocument(io.BytesIO(data))
    except Exception as error:
        raise UnreadablePdf(f"this file could not be rasterised: {error}") from error

    images: list[bytes] = []
    try:
        for page in document:
            bitmap = page.render(scale=dpi / 72)
            buffer = io.BytesIO()
            bitmap.to_pil().save(buffer, format="PNG")
            images.append(buffer.getvalue())
    finally:
        document.close()
    return images
