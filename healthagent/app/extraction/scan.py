"""Finding results on a page, deterministically.

**No LLM runs here and none ever will.** This module decides what the numbers on
a page are. The LLM is asked exactly one thing, later and elsewhere: which
biomarker a *label* names. Every value this produces is a span lifted verbatim
out of the page, which is what makes the verbatim check downstream meaningful
rather than circular — a check against a number we generated would prove nothing.

The misread this exists to prevent:

    Glucose, Fasting      142      mg/dL     70 - 100

"The first number after the label" is 142 here and 70 on a report that prints
the interval first. Both layouts ship. Reporting 70 turns a diabetic fasting
glucose into a healthy one, and nothing downstream could ever notice, because 70
is a perfectly plausible glucose.

So the scanner reads the table's own header to learn where its columns are, and
takes the result from the result column. Labs print that header because humans
need it too; it is the most reliable signal on the page, and far steadier than
inferring columns from where numbers happen to cluster.

When there is no header, this returns nothing. A page we cannot read the layout
of produces no results rather than guessed ones.
"""

import re
from dataclasses import dataclass

QUANTITATIVE = "quantitative"
QUALITATIVE = "qualitative"

# Words a lab uses to head each column. Several per column because no two labs
# agree, and matching is on the printed header rather than on position.
_HEADINGS = {
    "test": ("test", "tests", "investigation", "parameter", "particulars", "examination",
             "description", "analyte"),
    "result": ("result", "results", "value", "observed", "observation"),
    "unit": ("unit", "units"),
    "reference": ("reference", "ref", "ref.", "interval", "range", "biological",
                  "bio.", "normal"),
}

# Results that are not numbers and must never be coerced into one. Deliberately
# a closed set: anything outside it is not silently treated as a finding.
_QUALITATIVE_TERMS = frozenset({
    "negative", "positive", "reactive", "non-reactive", "nonreactive",
    "non reactive", "not detected", "detected", "trace", "absent", "present",
    "nil", "none detected", "no growth", "sterile", "indeterminate",
    "equivocal", "borderline",
})

# `<0.01`, `> 500`, `142`, `1,234`, `7.8`. The operator may be its own word.
_VALUE = re.compile(
    r"^(?P<operator>[<>≤≥]?)\s*"
    r"(?P<number>\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)$"
)

# Flags a lab prints beside an out-of-range result. Part of the cell, not of the
# value, and not something we re-derive — we have our own ranges.
_FLAGS = frozenset({"h", "l", "hh", "ll", "a", "*", "**", "high", "low", "abnormal"})

# ≤ and ≥ collapse to < and >. The distinction is immaterial downstream: either
# way the true value is unknown, which is what excludes it from biological age.
_OPERATORS = {"<": "<", ">": ">", "≤": "<", "≥": ">", "": "="}

# Words on one printed line rarely share an exact baseline once fonts differ.
_LINE_TOLERANCE = 3.0


@dataclass(frozen=True)
class Candidate:
    """One row of a results table, as printed. Nothing is interpreted yet —
    `label` is the lab's wording and `unit_text` is the lab's spelling."""

    label: str
    value_text: str
    operator: str
    unit_text: str | None
    reference_text: str | None
    result_type: str
    page: int
    bbox: dict

    def __eq__(self, other):  # dict field, so compare field by field
        return isinstance(other, Candidate) and vars(self) == vars(other)


def _lines(words):
    """Words grouped into printed lines, each ordered left to right."""
    lines: list[list] = []
    for word in sorted(words, key=lambda w: (w.top, w.x0)):
        if lines and abs(lines[-1][0].top - word.top) <= _LINE_TOLERANCE:
            lines[-1].append(word)
        else:
            lines.append([word])
    return [sorted(line, key=lambda w: w.x0) for line in lines]


def _find_columns(lines) -> dict[str, float] | None:
    """The x-position of each column, read off the table's own header row.

    The best line wins rather than the first: a report's title block can contain
    the word "Test", and a header that matches three categories is the table's.
    """
    best, best_score = None, 0
    for line in lines:
        found: dict[str, float] = {}
        for word in line:
            token = word.text.strip().lower().rstrip(":")
            for column, headings in _HEADINGS.items():
                if token in headings and column not in found:
                    found[column] = word.x0
        # A table needs somewhere to put the answer, and at least one more
        # column, or a sentence containing "result" would qualify.
        if "result" in found and len(found) >= 2 and len(found) > best_score:
            best, best_score = found, len(found)
    return best


def _boundaries(columns: dict[str, float]) -> list[tuple[str, float, float]]:
    """Half-open x ranges per column, split midway between their origins."""
    ordered = sorted(columns.items(), key=lambda item: item[1])
    spans = []
    for index, (name, start) in enumerate(ordered):
        low = float("-inf") if index == 0 else (ordered[index - 1][1] + start) / 2
        high = float("inf") if index == len(ordered) - 1 else (ordered[index + 1][1] + start) / 2
        spans.append((name, low, high))
    return spans


def _cells(line, spans) -> dict[str, list]:
    cells: dict[str, list] = {name: [] for name, _, _ in spans}
    for word in line:
        for name, low, high in spans:
            if low <= word.x0 < high:
                cells[name].append(word)
                break
    return cells


def _read_value(cell) -> tuple[str, str, str] | None:
    """(value, operator, result_type) for a result cell, or None if it is not one.

    This is the gate that keeps the page's other numbers out. A footer reading
    `Sample drawn at : Bhubaneswar Collection Centre, Code 25531` puts `25531`
    in the result column on a two-column split, and a "label then number"
    heuristic reports it as a finding. A result cell holds a value and at most a
    flag — not four words of prose.
    """
    tokens = [w.text.strip() for w in cell if w.text.strip()]
    if not tokens:
        return None

    meaningful = [t for t in tokens if t.lower() not in _FLAGS]
    if not meaningful:
        return None

    joined = " ".join(meaningful)
    if joined.lower() in _QUALITATIVE_TERMS:
        return joined, "=", QUALITATIVE

    # `< 3.0` splits into two words; `<3.0` does not. Both are one value.
    if len(meaningful) == 2 and meaningful[0] in _OPERATORS and meaningful[0]:
        joined = meaningful[0] + meaningful[1]
        meaningful = [joined]

    if len(meaningful) != 1:
        return None

    match = _VALUE.match(meaningful[0])
    if not match:
        return None
    return (
        match.group("number").replace(",", ""),
        _OPERATORS[match.group("operator")],
        QUANTITATIVE,
    )


def _text(cell) -> str | None:
    joined = " ".join(w.text for w in cell).strip()
    return joined or None


def _bbox(cell, page) -> dict:
    """Where the value sits, with the page it sits on.

    The page size travels with the box because the box alone cannot be used.
    Coordinates are points for a PDF and pixels for an OCR'd image, so a
    consumer needs the extent to turn them into a fraction of the page — and a
    fraction is what survives the image being served or scaled at any size.

    This is what lets the confirmation screen show the user the crop of their
    own report that a number was read from, which is the check that replaces
    the verbatim one when the text came from OCR.
    """
    return {
        "x0": min(w.x0 for w in cell),
        "x1": max(w.x1 for w in cell),
        "top": min(w.top for w in cell),
        "bottom": max(w.bottom for w in cell),
        "page_width": page.width,
        "page_height": page.height,
    }


def scan_page(page) -> list[Candidate]:
    """Every result printed on this page, in the order they appear.

    Pure: the same page always produces the same list, and nothing here reads a
    clock, a database or a model.
    """
    lines = _lines(page.words)
    columns = _find_columns(lines)
    if columns is None:
        return []

    spans = _boundaries(columns)
    header_top = min(
        line[0].top for line in lines
        if any(w.x0 == x for w in line for x in columns.values())
    )

    candidates = []
    for line in lines:
        if line[0].top <= header_top:
            continue  # the header itself, and the title block above it

        cells = _cells(line, spans)
        value = _read_value(cells.get("result", []))
        if value is None:
            continue

        label = _text(cells.get("test", []))
        # A number with nothing naming it cannot become a result.
        if not label or not any(c.isalpha() for c in label):
            continue

        value_text, operator, result_type = value
        candidates.append(
            Candidate(
                label=label,
                value_text=value_text,
                operator=operator,
                unit_text=_text(cells.get("unit", [])),
                reference_text=_text(cells.get("reference", [])),
                result_type=result_type,
                page=page.index,
                bbox=_bbox(cells["result"], page),
            )
        )
    return candidates
