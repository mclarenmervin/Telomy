"""Figures in prose must trace to something a tool returned.

The machinery was written for the activity report and is now shared, because a
fabricated number is a fabricated number whichever surface it appears on. The
one thing the concierge needs that a report did not is the distinction between
a figure and a *measurement claim*: in a conversation the model writes dates,
counts and ordinals constantly, and "2026" tracing to nothing is a year, while
"1.4 mg/dL" tracing to nothing is an invented blood test.
"""

from app.agent.numbers import check_numbers, collect_tool_numbers


class ToolMessage:
    type = "tool"

    def __init__(self, content):
        self.content = content


def test_a_figure_that_traces_to_a_tool_is_not_flagged():
    allowed = collect_tool_numbers(
        [ToolMessage('{"status": "ok", "items": [{"value": 68}]}')]
    )

    check = check_numbers("Your readiness was 68.", allowed)

    assert check.unverified == frozenset()
    assert check.measurements == frozenset()


def test_a_figure_that_traces_to_nothing_is_flagged():
    check = check_numbers("Your readiness was 91.", set())

    assert check.unverified == frozenset({"91"})


def test_a_unit_carrying_figure_is_a_measurement_claim():
    """The dangerous case, and the reason the two sets are separate. A number
    with a unit beside it is a statement about this person's body."""
    check = check_numbers("Your magnesium was 1.4 mg/dL last month.", set())

    assert "1.4" in check.measurements
    assert "1.4" in check.unverified


def test_a_year_is_not_a_measurement_claim():
    """A conversation is full of dates. If a year counted as an invented
    measurement, the check would fire on almost every honest reply and stop
    meaning anything — which is how a check gets switched off.

    It is not counted as an unsupported figure either, which is a correction
    made after running the concierge against live data: see the section at the
    bottom of this file.
    """
    check = check_numbers("Your panel from 3 October 2026 is the latest one.", set())

    assert check.measurements == frozenset()
    assert check.unverified == frozenset()


def test_small_bare_counts_are_forgiven():
    check = check_numbers("I found 3 findings and 2 reports.", set())

    assert check.unverified == frozenset()


def test_a_small_number_with_a_unit_is_still_a_claim():
    """An invented delta is the likeliest fabrication in this domain, and it is
    usually small: "3 bpm lower" must not slip through as a count."""
    check = check_numbers("Your resting heart rate is 3 bpm lower.", set())

    assert check.measurements == frozenset({"3"})


def test_tool_numbers_come_from_structured_values_not_prose():
    """An id or a timestamp must not launder a fabricated measurement. The
    insight body is a string, so figures inside it are not admitted by having
    been returned — quoting it is handled by the guardrail's signed-quote path,
    not by pretending the number was computed."""
    allowed = collect_tool_numbers([ToolMessage(
        '{"items": [{"id": 93, "recorded_at": "2026-10-11T07:00:00",'
        ' "body": "Magnesium was 1.4 mg/dL."}]}'
    )])

    assert "93" not in allowed
    assert "1.4" not in allowed


# ── Tokens that are not figures at all ───────────────────────────────────────
#
# Found by running the concierge against live data: two honest answers came
# back flagged. One mentioned a date, the other named the clinician who signed
# a finding — "Dr Meera Raghavan, KMC-2019-44871" — and the check read 2019 and
# 44871 as claims about somebody's body.
#
# That is the failure the report's own comment warns about: a check that fires
# on nearly every honest sentence stops carrying information, and then somebody
# switches it off. A conversation names dates and people constantly where a
# report never did.
#
# A unit still overrides all of this, because a unit is what makes a figure a
# measurement. "1.7-2.2 mg/dL" must stay catchable even though the 2.2 sits
# inside a compound token.

def test_a_registration_number_is_not_a_measurement():
    check = check_numbers("Dr Meera Raghavan, KMC-2019-44871, signed this.", set())

    assert check.unverified == frozenset()


def test_an_iso_date_is_not_a_measurement():
    check = check_numbers("The stored result is for 2026-10-10.", set())

    assert check.unverified == frozenset()


def test_a_written_year_is_not_a_measurement():
    check = check_numbers("Your panel was taken in October 2026.", set())

    assert check.unverified == frozenset()


def test_a_bare_figure_with_no_unit_is_still_flagged():
    """The forgiveness is for compound tokens and years, not for free-standing
    numbers the model produced out of nowhere."""
    check = check_numbers("Your score came out at 91 overall.", set())

    assert check.unverified == frozenset({"91"})


def test_a_unit_overrides_every_forgiveness():
    """A fabricated range is a compound token, and it is exactly the kind of
    claim that must not slip through on a technicality."""
    check = check_numbers("The standard range is 1.7-2.2 mg/dL.", set())

    assert "2.2" in check.measurements


def test_a_year_with_a_unit_is_still_a_claim():
    check = check_numbers("Your ferritin was 2026 ng/mL.", set())

    assert "2026" in check.measurements
