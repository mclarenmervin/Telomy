"""Turning scanned pages into rows we would be willing to store.

Three things happen here that happen nowhere else.

**The verbatim check.** Every value must appear, as printed, in the text of the
page it came from. The scanner lifts spans, so this holds by construction —
which is precisely why it is asserted rather than assumed. It is the guard that
makes P2 enforceable: the day anything starts *computing* a value instead of
reading one, ingestion stops rather than quietly storing a number nobody printed.

**Dates.** Collection, report and registration dates are three different things,
and real reports label none of them unambiguously. Trending uses the collection
date; getting it wrong puts a 2023 panel on today's chart. Where we cannot be
sure, we say so rather than guess, and the confirmation screen asks.

**The history rule.** A new user uploading five years of reports in one sitting
must not receive five years of retroactive alerts, five clinician drafts, or a
recompute storm.
"""

import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from app.analytics import catalog, units
from app.common.logging_config import get_logger
from app.extraction.mapping import STANDARD, map_unit, resolve_labels
from app.extraction.scan import QUANTITATIVE, scan_page

logger = get_logger(__name__)

# Bumped when extraction behaviour changes, so a row can be traced to the code
# that produced it and re-extraction can be targeted.
EXTRACTION_VERSION = "lab-extract.v1"

# Older than this and the report populates trends but generates no alerts and no
# clinician drafts. 90 days matches the quarterly panel cadence: a sample from
# last month still describes you, one from 2021 does not.
HISTORY_DAYS = 90

EXTRACTED = "extracted"
USER = "user"
UNKNOWN = "unknown"

_MONTHS = {
    m: i + 1 for i, m in enumerate(
        "jan feb mar apr may jun jul aug sep oct nov dec".split()
    )
}

# Labels a report puts in front of each date. Longest first, so "collected on"
# is not matched by a looser "collected" pattern on a different line.
_COLLECTION_LABELS = (
    "sample collected on", "collected on", "collection date", "sample drawn on",
    "sample collected", "drawn on", "collected",
)
_REPORT_LABELS = (
    "reported on", "report date", "released on", "reporting date", "reported",
)

_NUMERIC_DATE = re.compile(r"\b(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2,4})\b")
_NAMED_DATE = re.compile(r"\b(\d{1,2})[\s\-]([A-Za-z]{3,9})[\s\-](\d{2,4})\b")
_ISO_DATE = re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b")

_PATIENT_LABELS = ("patient name", "patient's name", "name of patient", "patient")


class VerbatimCheckFailed(Exception):
    """A value we were about to store is not on the page it claims to come from.

    Never caught. This is the signal that something has started producing values
    rather than reading them, and storing the row would defeat the one property
    the whole extraction design rests on.
    """


@dataclass(frozen=True)
class ExtractedResult:
    biomarker_id: str
    context: str
    result_type: str
    operator: str
    raw_value: str
    raw_unit: str | None
    value_canonical: float | None
    value_text: str | None
    unit_canonical: str | None
    page: int
    bbox: dict
    confidence: float
    catalog_version: str

    def __eq__(self, other):  # dict field
        return isinstance(other, ExtractedResult) and vars(self) == vars(other)


@dataclass(frozen=True)
class ExtractedReport:
    results: tuple[ExtractedResult, ...]
    skipped: tuple[tuple[str, str], ...]  # (printed label, why)
    collected_at: datetime | None
    collected_at_source: str
    reported_at: datetime | None
    patient_name: str | None
    lab_name: str | None
    is_history: bool
    page_count: int
    text_layer: str
    extraction_version: str = EXTRACTION_VERSION


def _year(raw: int) -> int:
    return raw + 2000 if raw < 100 else raw


def _find_labelled_date(text: str, labels) -> tuple[datetime | None, bool]:
    """(date, unambiguous) for the first of `labels` that is followed by one.

    Ambiguity is dd/mm versus mm/dd: `03/04/2026` is 3 April in India and
    4 March on a US-formatted report. We read it the Indian way — this is the
    market — and report it as ambiguous so the confirmation screen asks instead
    of silently choosing.
    """
    # Bounded to the label's own line, and this is load bearing. Searching a
    # fixed window of characters instead runs onto the following line, so a
    # report whose collection date is blank or unreadable silently takes the
    # *report* date from the line below — which is precisely the substitution
    # that puts a panel on the wrong day. Found by the test for it.
    for label in labels:
        for line in text.splitlines():
            position = line.lower().find(label)
            if position < 0:
                continue
            parsed = _parse_date(line[position + len(label) :])
            if parsed is not None:
                return parsed
    return None, False


def _parse_date(window: str) -> tuple[datetime, bool] | None:
    iso = _ISO_DATE.search(window)
    if iso:
        y, m, d = (int(g) for g in iso.groups())
        return datetime(y, m, d, tzinfo=timezone.utc), True

    named = _NAMED_DATE.search(window)
    if named:
        day, month_name, year = named.groups()
        month = _MONTHS.get(month_name[:3].lower())
        if month:
            return datetime(_year(int(year)), month, int(day), tzinfo=timezone.utc), True

    numeric = _NUMERIC_DATE.search(window)
    if numeric:
        first, second, year = (int(g) for g in numeric.groups())
        if first > 12 and second <= 12:
            day, month, certain = first, second, True
        elif second > 12 and first <= 12:
            day, month, certain = second, first, True  # mm/dd/yyyy
        else:
            day, month, certain = first, second, False  # both plausible
        try:
            return datetime(_year(year), month, day, tzinfo=timezone.utc), certain
        except ValueError:
            return None
    return None


def _find_patient_name(text: str) -> str | None:
    for line in text.splitlines():
        lowered = line.lower()
        for label in _PATIENT_LABELS:
            position = lowered.find(label)
            if position < 0:
                continue
            tail = line[position + len(label) :].lstrip(" :\t")
            # Reports put two fields on one line; the second starts at its own
            # capitalised label, so stop at a run of two or more spaces.
            name = re.split(r"\s{2,}", tail)[0].strip()
            if name:
                return name
    return None


def _find_lab_name(text: str) -> str | None:
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return None


def _canonical(biomarker_id: str, raw_value: str, raw_unit: str | None):
    """(value, unit) in the catalog's units, or None when we cannot convert.

    None rather than a guess: a wrong conversion and a real abnormal result are
    indistinguishable once the number is on a chart.
    """
    unit = map_unit(biomarker_id, raw_unit)
    if unit is None:
        return None, None
    try:
        return units.to_canonical(biomarker_id, float(raw_value), unit), \
            catalog.get(biomarker_id).canonical_unit
    except (units.UnknownUnit, ValueError, TypeError, AttributeError):
        return None, None


def extract_report(document, now: datetime | None = None) -> ExtractedReport:
    """Everything we would store from one uploaded report.

    `llm` is deliberately absent: label mapping is injected by the worker, so
    this stays a pure function of the document for every test that matters.
    """
    now = now or datetime.now(timezone.utc)
    full_text = "\n".join(page.text for page in document.pages)

    candidates = [c for page in document.pages for c in scan_page(page)]
    mapped = resolve_labels([c.label for c in candidates])

    results: list[ExtractedResult] = []
    skipped: list[tuple[str, str]] = []

    for candidate in candidates:
        page_text = document.pages[candidate.page].text
        # Before anything else is done with it. A value that is not on the page
        # must never reach a conversion, let alone a row.
        if candidate.value_text not in page_text:
            raise VerbatimCheckFailed(
                f"{candidate.label!r}: the value {candidate.value_text!r} does not "
                f"appear on page {candidate.page}"
            )

        mapping = mapped.get(candidate.label)
        if mapping is None or mapping.biomarker_id is None:
            skipped.append((candidate.label, "no biomarker in the catalog matches this label"))
            continue

        if candidate.result_type != QUANTITATIVE:
            skipped.append((candidate.label, "qualitative results are not yet stored"))
            continue

        value, unit = _canonical(mapping.biomarker_id, candidate.value_text, candidate.unit_text)
        if value is None:
            skipped.append(
                (candidate.label, f"unit {candidate.unit_text!r} cannot be converted")
            )
            continue

        results.append(
            ExtractedResult(
                biomarker_id=mapping.biomarker_id,
                context=mapping.context or STANDARD,
                result_type=candidate.result_type,
                operator=candidate.operator,
                raw_value=candidate.value_text,
                raw_unit=candidate.unit_text,
                value_canonical=value,
                value_text=None,
                unit_canonical=unit,
                page=candidate.page,
                bbox=candidate.bbox,
                confidence=mapping.confidence,
                catalog_version=catalog.catalog_version(),
            )
        )

    collected_at, certain = _find_labelled_date(full_text, _COLLECTION_LABELS)
    reported_at, _ = _find_labelled_date(full_text, _REPORT_LABELS)

    # An undated panel might be from 2019. Firing alerts on it is the worse of
    # the two mistakes, so it is history until the user tells us otherwise.
    is_history = (
        collected_at is None or collected_at < now - timedelta(days=HISTORY_DAYS)
    )

    return ExtractedReport(
        results=tuple(results),
        skipped=tuple(skipped),
        collected_at=collected_at,
        collected_at_source=EXTRACTED if (collected_at and certain) else UNKNOWN,
        reported_at=reported_at,
        patient_name=_find_patient_name(full_text),
        lab_name=_find_lab_name(full_text),
        is_history=is_history,
        page_count=len(document.pages),
        text_layer=document.text_layer,
    )
