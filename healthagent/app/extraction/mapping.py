"""Deciding which biomarker a printed label names.

This is the **only** place an LLM touches lab extraction, and it is asked
exactly one kind of question: the lab printed `FBS (F)` — which marker is that?
It is never asked what a value is, never asked to convert a unit, and never
shown a number it could return.

The guarantee is structural, not behavioural. `resolve_labels` takes label
strings. There is no parameter through which a value could reach it, so no
prompt it builds can contain one. That is what makes the verbatim check
downstream meaningful: the number came off the page, and the model had no
opportunity to touch it.

Two tiers, deterministic first:

**The catalog's alias table** answers the great majority. Indian panels print
predictable names, and a table in git is cheaper, instant, reviewable in a pull
request and immune to a bad generation. A build with no model configured still
extracts a full panel — the table is the product, not a cache in front of a
model.

**The model** sees only what the table could not place, and what it returns is
not trusted: an id that is not in the catalog is discarded rather than written,
because a hallucinated marker would become a row with no ranges, no units and
no citation.
"""

import json
import re
from dataclasses import dataclass

from app.analytics import catalog, units
from app.analytics.catalog import normalise_label
from app.common.logging_config import get_logger

logger = get_logger(__name__)

ALIAS = "alias"
LLM = "llm"
UNMAPPED = "unmapped"

STANDARD = "standard"

# An alias match is the catalog agreeing with itself. A model answer is a guess
# we have chosen to accept, and the confirmation screen should not present the
# two with equal certainty.
ALIAS_CONFIDENCE = 1.0
LLM_CONFIDENCE = 0.6

# Contexts that change what a number means. Fasting and post-prandial glucose
# are one marker and two results; the context separates them in the uniqueness
# key, and keeps a post-prandial value from being graded against fasting ranges.
_CONTEXTS = (
    ("post_prandial", re.compile(r"\b(post prandial|postprandial|pp|ppbs|2 hour|2 hr)\b")),
    ("random", re.compile(r"\b(random|rbs)\b")),
    ("fasting", re.compile(r"\b(fasting|fbs|f)\b")),
)

# How labs print units, folded onto the spellings the catalog converts. This is
# a reading concern, not a conversion one, so it lives here rather than in
# `analytics.units`, which stays the single authority on the arithmetic.
# Keys and values are both already normalised by `normalise_unit_label`.
_UNIT_SYNONYMS = {
    "mgs/dl": "mg/dl",
    "mg%": "mg/dl",
    "mgs%": "mg/dl",
    "gms/dl": "g/dl",
    "gm/dl": "g/dl",
    "gms%": "g/dl",
    "gm%": "g/dl",
    "g%": "g/dl",
    "mg/100ml": "mg/dl",
    "g/100ml": "g/dl",
    "miu/l": "uiu/ml",  # numerically identical for TSH
    "mcg/dl": "ug/dl",
    "mcg/l": "ug/l",
    "mcmol/l": "umol/l",
    "ng/dl": "ng/dl",
    "cells/cumm": "cells/ul",
    "cells/cu mm": "cells/ul",
    "/cumm": "cells/ul",
}

_PROMPT = (
    "You map laboratory test names to biomarker identifiers.\n"
    "Reply with JSON only: an object mapping each given test name to one "
    "identifier from the list, or to null if none of them is the same analyte.\n"
    "Never invent an identifier. Never guess at a near match: a wrong mapping "
    "files a real measurement under the wrong marker, which is worse than "
    "leaving it unmapped.\n"
)


@dataclass(frozen=True)
class LabelMapping:
    """What we concluded a printed label refers to.

    Deliberately carries no value, no unit and no number — there is nowhere for
    one to be smuggled in, even if a model volunteered it.
    """

    biomarker_id: str | None
    context: str
    source: str
    confidence: float


def _context_for(normalised: str) -> str:
    for name, pattern in _CONTEXTS:
        if pattern.search(normalised):
            return name
    return STANDARD


def _catalogue_for_prompt() -> str:
    _, markers = catalog.load_catalog()
    return "\n".join(f"{m.id}: {m.name}" for m in markers.values())


def _ask_model(llm, labels: list[str]) -> dict[str, str]:
    """{label: biomarker_id} for labels the alias table could not place.

    Only the labels are sent. Anything the model returns that is not a marker we
    carry, or not a label we asked about, is dropped.
    """
    request = (
        f"{_PROMPT}\nIdentifiers:\n{_catalogue_for_prompt()}\n\n"
        f"Test names:\n" + "\n".join(labels)
    )
    try:
        raw = str(llm.invoke([("system", _PROMPT), ("human", request)]).content)
    except Exception:
        logger.exception("label mapping model call failed; leaving labels unmapped")
        return {}

    try:
        answer = json.loads(raw[raw.index("{") : raw.rindex("}") + 1])
    except (ValueError, json.JSONDecodeError):
        logger.warning("label mapping model returned no usable JSON")
        return {}
    if not isinstance(answer, dict):
        return {}

    _, markers = catalog.load_catalog()
    asked = set(labels)
    return {
        label: biomarker_id
        for label, biomarker_id in answer.items()
        if label in asked and biomarker_id in markers
    }


def resolve_labels(labels, llm=None) -> dict[str, LabelMapping]:
    """{printed label: what it maps to}. Unknown labels stay unmapped.

    `llm` is optional on purpose: extraction must work without one.
    """
    unique = list(dict.fromkeys(labels))
    index = catalog.alias_index()

    resolved: dict[str, LabelMapping] = {}
    unplaced: list[str] = []
    for label in unique:
        normalised = normalise_label(label)
        biomarker_id = index.get(normalised)
        if biomarker_id is None:
            unplaced.append(label)
            continue
        resolved[label] = LabelMapping(
            biomarker_id=biomarker_id,
            context=_context_for(normalised),
            source=ALIAS,
            confidence=ALIAS_CONFIDENCE,
        )

    answers = _ask_model(llm, unplaced) if (llm is not None and unplaced) else {}
    for label in unplaced:
        biomarker_id = answers.get(label)
        resolved[label] = LabelMapping(
            biomarker_id=biomarker_id,
            context=_context_for(normalise_label(label)),
            source=LLM if biomarker_id else UNMAPPED,
            confidence=LLM_CONFIDENCE if biomarker_id else 0.0,
        )
    return resolved


def map_unit(biomarker_id: str, unit_text: str | None) -> str | None:
    """The catalog's spelling of a printed unit, or None.

    None rather than a guess: a wrong conversion is indistinguishable from a
    real abnormal result once it is a number on a chart. The arithmetic itself
    stays in `analytics.units`, which is the only thing that performs it.
    """
    if not unit_text or not unit_text.strip():
        return None
    marker = catalog.get(biomarker_id)
    if marker is None:
        return None

    wanted = units.normalise_unit_label(unit_text)
    wanted = _UNIT_SYNONYMS.get(wanted, wanted)
    if wanted not in marker.conversions:
        return None
    # Return the catalog's own spelling so storage is consistent regardless of
    # how the lab wrote it.
    if wanted == units.normalise_unit_label(marker.canonical_unit):
        return marker.canonical_unit
    return unit_text.strip()
