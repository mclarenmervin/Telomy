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
