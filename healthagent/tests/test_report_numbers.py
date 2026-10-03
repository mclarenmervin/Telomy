from types import SimpleNamespace

from app.activity_agent.report import collect_tool_numbers, verify_numbers


def report(body):
    return {"headline": "A session.",
            "sections": [{"id": "what_happened", "title": "t", "body": body}]}


ANALYSIS = {"metrics": [{"key": "heartRate", "value": 130.0, "min": 120, "max": 140,
                         "baseline": 125.0, "delta": 5.0, "samples": 60}],
            "baseline": {}, "score": {"value": 70}, "duration_seconds": 1800,
            "history_used": {"sessions_compared": 5}}


def test_a_number_from_nowhere_is_still_flagged():
    _, flags = verify_numbers(report("Your ferritin was 42 ng/mL."), ANALYSIS)

    assert "unverified_number" in flags


def test_a_number_returned_by_a_tool_is_accepted():
    """Without this, enabling tool-driven context makes the flag fire on almost
    every richer report, which destroys its signal."""
    allowed = {"42"}

    _, flags = verify_numbers(report("Your ferritin was 42 ng/mL."), ANALYSIS, allowed)

    assert flags == []


def test_collect_tool_numbers_reads_tool_message_content():
    messages = [
        SimpleNamespace(type="tool", content='{"items": [{"value": 42, "unit": "ng/mL"}]}'),
        SimpleNamespace(type="ai", content="ignored 999"),
    ]

    numbers = collect_tool_numbers(messages)

    assert "42" in numbers
    assert "999" not in numbers


def test_collect_tool_numbers_tolerates_odd_messages():
    assert collect_tool_numbers(None) == set()
    assert collect_tool_numbers([SimpleNamespace(type="tool", content=None)]) == set()
    assert collect_tool_numbers([{"no": "attrs"}]) == set()


def test_row_ids_and_timestamps_are_not_admitted_as_measurements():
    """A tool returning an id of 93 would otherwise legitimise the model writing
    'your blood oxygen was 93%' — the check is meant to catch exactly that."""
    messages = [SimpleNamespace(
        type="tool",
        content='{"items": [{"id": 93, "taken_at": "2026-10-02T14:33:07", "value": 41}]}',
    )]

    numbers = collect_tool_numbers(messages)

    assert "41" in numbers          # a real measurement value
    assert "93" not in numbers      # a row id
    assert "2026" not in numbers    # a timestamp component
    assert "33" not in numbers


def test_a_very_long_digit_run_does_not_raise():
    """float('9'*400) is inf and int(inf) throws; the caller swallows it as a failed
    narration, silently discarding a good report."""
    messages = [SimpleNamespace(type="tool", content="9" * 400)]

    assert collect_tool_numbers(messages) is not None
