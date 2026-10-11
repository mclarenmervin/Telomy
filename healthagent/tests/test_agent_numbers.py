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
    meaning anything — which is how a check gets switched off."""
    check = check_numbers("Your panel from 3 October 2026 is the latest one.", set())

    assert check.measurements == frozenset()
    assert "2026" in check.unverified


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
