"""Does a figure in prose trace to something a tool actually returned?

Written for the activity report and shared from F7, because a fabricated number
is a fabricated number whichever surface it appears on — and the concierge is a
surface where the model writes freely, at a person's request, with no section
schema narrowing what it can say.

The check is deliberately cheap and deliberately not an LLM. It harvests the
numeric *values* a tool returned, then looks at every figure in the prose and
asks whether it is one of them.

Two sets come back rather than one, which is the only thing F7 added. In a
conversation the model writes dates, counts and ordinals constantly: "2026"
tracing to nothing is a year and not worth refusing a reply over, while
"1.4 mg/dL" tracing to nothing is an invented blood test. A unit beside a
number is what separates them, and it is the same signal the report has always
used to tell a measurement from a count.
"""

import json
import math
import re

from dataclasses import dataclass

_NUMBER = re.compile(r"\d+(?:\.\d+)?")
SMALL_NUMBER_LIMIT = 10  # bare counts like "3 sessions" are unremarkable
# A small number carrying a unit is a measurement claim, not a count, and must reconcile:
# an invented delta ("3 bpm lower") is the likeliest fabrication in this domain.
_UNIT_AFTER = re.compile(
    r"\s*(?:%|bpm|beats|percent|hours?|hrs?|minutes?|mins?|seconds?|secs?|kg|lbs?|ms|°"
    # Lab units, added in F7. The activity report never needed them because it
    # narrates sensor metrics; the concierge discusses blood tests, where the
    # whole claim *is* a number and its unit.
    #
    # It also tightens the report, in the direction the comment above already
    # argues for: "4 mg/dL" used to be forgiven as a bare count under
    # SMALL_NUMBER_LIMIT, and a lab value is not a count.
    r"|mg/dL|mg/L|g/dL|g/L|mmol/L|[µu]mol/L|nmol/L|pmol/L|ng/mL|ng/dL|pg/mL"
    r"|[µu]g/dL|[µu]g/L|mIU/mL|mIU/L|IU/L|U/L|fL|pg|mmHg|years?|yrs?"
    r")\b",
    re.I,
)


# Fields that identify or timestamp a row rather than measure the user. A tool
# returning {"id": 93} must not legitimise the model writing "your blood oxygen was 93".
_NON_MEASUREMENT_KEY = re.compile(
    r"(?:^|_)(?:id|ids|uuid|pk|index|idx)$|_at$|^(?:created|updated|recorded|taken)|"
    r"date|time|timestamp|version",
    re.I,
)
_MAX_PLAUSIBLE = 1e9  # beyond this it is not a health measurement


def _admit(value, into: set[str]) -> None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return
    # Magnitude first: math.isfinite() casts to float, which itself overflows on a
    # very long digit run, and the exception would be swallowed as a failed narration.
    if abs(value) > _MAX_PLAUSIBLE or not math.isfinite(value):
        return
    magnitude = abs(value)
    for form in (int(magnitude), round(magnitude), magnitude):
        into.add(f"{form:.0f}")
        into.add(f"{form:.1f}")
        into.add(f"{form:.1f}".rstrip("0").rstrip("."))


def _walk(node, into: set[str]) -> None:
    """Harvest numeric VALUES, skipping identifier and timestamp fields."""
    if isinstance(node, dict):
        for key, value in node.items():
            if isinstance(key, str) and _NON_MEASUREMENT_KEY.search(key):
                continue
            _walk(value, into)
    elif isinstance(node, list):
        for item in node:
            _walk(item, into)
    else:
        _admit(node, into)


def collect_tool_numbers(messages) -> set[str]:
    """Numbers a tool actually returned during this run.

    Once the agent fetches labs or measurements, it legitimately cites figures that
    are not in `analysis`. Without admitting them, `unverified_number` fires on
    nearly every richer report, stops carrying information, and creates pressure to
    switch the check off — which is how a fabricated health number reaches a user.

    Values are read from the tool's structured return rather than by regexing its
    serialised text, so row ids and ISO timestamps cannot launder a fabricated
    measurement past the check.
    """
    found: set[str] = set()
    for message in messages or []:
        if getattr(message, "type", None) != "tool":
            continue
        content = getattr(message, "content", None)
        if not isinstance(content, str):
            continue
        try:
            _walk(json.loads(content), found)
        except (ValueError, TypeError):
            # Not JSON: admit nothing rather than regexing arbitrary prose, which is
            # how ids and timestamps got in.
            continue
    return found


# A figure that is part of a longer alphanumeric token: a registration number
# ("KMC-2019-44871"), an ISO date ("2026-10-10"), an id. Found by running the
# concierge against live data, where naming the clinician who signed a finding
# was enough to flag an honest answer. A conversation names dates and people
# constantly, where a report never did.
_INSIDE_A_TOKEN = re.compile(r"[A-Za-z0-9]-|/|\d-$")

# Years, which a conversation about lab history cannot avoid. Bounded rather
# than "any four digits", so a four-digit measurement is still a measurement.
_YEAR_RANGE = (1900, 2100)


def _is_year(token: str) -> bool:
    return (
        len(token) == 4
        and token.isdigit()
        and _YEAR_RANGE[0] <= int(token) <= _YEAR_RANGE[1]
    )


@dataclass(frozen=True)
class NumberCheck:
    """What a piece of prose claims that nothing backs up.

    `measurements` is a subset of `unverified`: the figures carrying a unit,
    which are claims about this person's body rather than dates or counts.
    """

    unverified: frozenset[str]
    measurements: frozenset[str]


def check_numbers(text: str, allowed) -> NumberCheck:
    """Figures in `text` that do not trace to `allowed`.

    A bare integer up to SMALL_NUMBER_LIMIT is forgiven: "3 findings" is a
    count and refusing it would make the check fire on nearly every honest
    sentence, which is how a check stops carrying information and then gets
    switched off. A small number carrying a unit is not forgiven, because an
    invented delta is the likeliest fabrication in this domain and it is
    usually small.
    """
    allowed = set(allowed or ())
    unverified: set[str] = set()
    measurements: set[str] = set()
    for match in _NUMBER.finditer(text):
        token = match.group()
        if token in allowed:
            continue
        # A unit beside the number is checked first and forgives nothing
        # below, because a unit is what makes a figure a claim about a body.
        # "1.7-2.2 mg/dL" sits inside a compound token and a fabricated range
        # is exactly the claim that must not pass on a technicality.
        if _UNIT_AFTER.match(text, match.end()):
            unverified.add(token)
            measurements.add(token)
            continue
        if _is_year(token):
            continue
        if _INSIDE_A_TOKEN.search(text[max(0, match.start() - 2) : match.start()]):
            continue
        if float(token).is_integer() and float(token) <= SMALL_NUMBER_LIMIT:
            continue
        unverified.add(token)
    return NumberCheck(frozenset(unverified), frozenset(measurements))
