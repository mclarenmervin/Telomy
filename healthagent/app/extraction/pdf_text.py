"""Words and their positions, out of a lab PDF.

No interpretation happens here. The job is to hand the scanner words with
coordinates, because position is the mechanism that tells a result from the
reference interval printed beside it. A text extractor that returns a flat
string has already destroyed the information the scanner needs:

    Glucose, Fasting      142      mg/dL     70 - 100

flattens to `Glucose, Fasting 142 mg/dL 70 - 100`, where "the first number after
the label" is 142 on one report and 70 on the next, depending on column order.
With x-coordinates it is the number in the result column, always.

`pdfplumber` over `pypdf` because it exposes per-word bounding boxes; over
PyMuPDF because that is AGPL.

Failures are named rather than generic. "Extraction failed" is useless to
someone holding a password-protected report — standard practice for Indian labs,
often with the date of birth as the password — who needs a prompt and a retry.
"""

import io
from dataclasses import dataclass

import pdfplumber
from pdfminer.pdfdocument import PDFPasswordIncorrect
from pdfminer.pdfparser import PDFSyntaxError

# How the document's text was obtained. Mirrors lab_uploads.text_layer, because
# an OCR-derived result must be forced through confirmation.
NATIVE = "native"
OCR = "ocr"
NONE = "none"


class PasswordRequired(Exception):
    """Encrypted, and we do not have the password.

    Not a failure state: the upload is parked at `needs_password` and the user
    is asked. Raised for a wrong password too — from the user's side those are
    the same situation and the same prompt.
    """


class UnreadablePdf(Exception):
    """Not a PDF, or too corrupt to open.

    Uploaded files are untrusted, so this must fail by name rather than as
    whatever pdfminer happens to raise from deep inside a parser.
    """


@dataclass(frozen=True)
class Word:
    """One word and where it sits. Coordinates are in points from the top-left."""

    text: str
    x0: float
    x1: float
    top: float
    bottom: float

    @property
    def midpoint(self) -> float:
        return (self.x0 + self.x1) / 2


@dataclass(frozen=True)
class Page:
    index: int  # zero-based; this is what biomarker_results.page refers to
    words: tuple[Word, ...]
    text: str
    width: float
    height: float


@dataclass(frozen=True)
class Document:
    pages: tuple[Page, ...]
    text_layer: str

    @property
    def has_text(self) -> bool:
        return self.text_layer != NONE


def _causes(error: BaseException) -> list[BaseException]:
    """The exception and everything it was raised from.

    `pdfplumber` wraps pdfminer's exceptions in a `PdfminerException` that
    carries no message of its own — `str()` on it is empty — and attaches the
    real one to `__context__`. Sniffing the message for "password" therefore
    finds nothing, and an encrypted report gets reported as corrupt.
    """
    seen: set[int] = set()
    chain: list[BaseException] = []
    current: BaseException | None = error
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        chain.append(current)
        current = current.__cause__ or current.__context__
    return chain


def _word(raw: dict) -> Word:
    return Word(
        text=raw["text"],
        x0=float(raw["x0"]),
        x1=float(raw["x1"]),
        top=float(raw["top"]),
        bottom=float(raw["bottom"]),
    )


def read_pdf(data: bytes, password: str | None = None) -> Document:
    """Every page's words and text.

    A document with no words anywhere is reported as `text_layer='none'` rather
    than raised: a photographed report is the common case here, not an error,
    and the upload is routed to OCR instead of being failed.
    """
    if not data:
        raise UnreadablePdf("the uploaded file is empty")

    try:
        with pdfplumber.open(io.BytesIO(data), password=password or "") as pdf:
            pages = tuple(
                Page(
                    index=index,
                    words=tuple(_word(w) for w in page.extract_words()),
                    text=page.extract_text() or "",
                    width=float(page.width),
                    height=float(page.height),
                )
                for index, page in enumerate(pdf.pages)
            )
    except Exception as error:
        causes = _causes(error)
        # Password first: a wrong password and a missing one are the same
        # situation from the user's side, and neither is a corrupt file.
        if any(isinstance(cause, PDFPasswordIncorrect) for cause in causes):
            raise PasswordRequired("this report is password protected") from error
        if any(isinstance(cause, PDFSyntaxError) for cause in causes):
            raise UnreadablePdf("this file is not a readable PDF") from error
        detail = next((str(c) for c in causes if str(c)), "no detail available")
        raise UnreadablePdf(f"this file could not be read as a PDF: {detail}") from error

    has_words = any(page.words for page in pages)
    return Document(pages=pages, text_layer=NATIVE if has_words else NONE)
