"""What a conversation reads: its own history, and anything urgent.

Both go through the one scoped loader, like everything else. The history half
matters more than it looks: these rows are fed back into the next turn's prompt,
so a query that returned somebody else's turn would be a cross-tenant leak
*into the model's own context*, where no later check would catch it.
"""

from app.common.context_loader import ContextLoader
from tests.fakes import FakeSupabase

USER = "11111111-0000-4000-8000-000000000001"
OTHER = "22222222-0000-4000-8000-000000000002"


def turn(user_id=USER, asked="why?", answered="because.", created_at="2026-10-11T09:00:00+00:00"):
    return {
        "id": f"t-{created_at}-{user_id}",
        "user_id": user_id,
        "asked": asked,
        "answered": answered,
        "route": "answered",
        "guardrail_flags": [],
        "quoted_insight_ids": [],
        "model": "gpt-test",
        "created_at": created_at,
    }


def test_history_is_only_this_users_turns():
    loader = ContextLoader(FakeSupabase({"chat_turns": [
        turn(user_id=USER, asked="mine"),
        turn(user_id=OTHER, asked="theirs", created_at="2026-10-11T09:30:00+00:00"),
    ]}))

    out = loader.chat_turns(USER)

    assert [t["asked"] for t in out["items"]] == ["mine"]


def test_history_is_newest_first_and_bounded():
    rows = [
        turn(asked=f"q{n}", created_at=f"2026-10-11T0{n}:00:00+00:00") for n in range(1, 8)
    ]
    loader = ContextLoader(FakeSupabase({"chat_turns": rows}))

    out = loader.chat_turns(USER, limit=3)

    assert [t["asked"] for t in out["items"]] == ["q7", "q6", "q5"]


def test_history_carries_what_was_actually_said():
    """`answered` is the text after the guardrails ran, which is the only
    version worth feeding back: replaying a reply the user never saw would have
    the model build on words that were replaced."""
    loader = ContextLoader(FakeSupabase({"chat_turns": [turn(answered="Your readiness was 68.")]}))

    assert loader.chat_turns(USER)["items"][0]["answered"] == "Your readiness was 68."


def test_turns_today_counts_only_this_user():
    """The budget cap is per person. Counting everybody's turns would let one
    busy user mute the product for everyone."""
    loader = ContextLoader(FakeSupabase({"chat_turns": [
        turn(created_at="2026-10-11T08:00:00+00:00"),
        turn(created_at="2026-10-11T08:30:00+00:00"),
        turn(user_id=OTHER, created_at="2026-10-11T08:40:00+00:00"),
    ]}))

    assert loader.turns_since(USER, "2026-10-11T00:00:00+00:00") == 2


def test_turns_today_excludes_older_turns():
    loader = ContextLoader(FakeSupabase({"chat_turns": [
        turn(created_at="2026-10-09T23:00:00+00:00"),
        turn(created_at="2026-10-11T08:00:00+00:00"),
    ]}))

    assert loader.turns_since(USER, "2026-10-11T00:00:00+00:00") == 1


def test_an_open_escalation_is_visible_to_the_conversation():
    """A critical value cannot wait for a conversation, and the conversation
    must not be where it is quietly dropped either."""
    loader = ContextLoader(FakeSupabase({"lab_escalations": [{
        "id": "e1", "user_id": USER, "biomarker_id": "potassium",
        "value_canonical": 7.0, "operator": "=", "unit": "mmol/L",
        "severity": "critical", "message": "Potassium is critically high.",
        "acknowledged_at": None, "created_at": "2026-10-11T07:00:00+00:00",
    }]}))

    out = loader.open_lab_escalations(USER)

    assert out["items"][0]["biomarker_id"] == "potassium"


def test_an_acknowledged_escalation_is_not_open():
    """Open means "this person has not seen it yet". Repeating an acknowledged
    critical value in every reply forever is how a warning stops being read."""
    loader = ContextLoader(FakeSupabase({"lab_escalations": [{
        "id": "e1", "user_id": USER, "biomarker_id": "potassium",
        "value_canonical": 7.0, "operator": "=", "unit": "mmol/L",
        "severity": "critical", "message": "Potassium is critically high.",
        "acknowledged_at": "2026-10-11T07:30:00+00:00",
        "created_at": "2026-10-11T07:00:00+00:00",
    }]}))

    assert loader.open_lab_escalations(USER)["items"] == []


def test_another_users_escalation_is_not_visible():
    loader = ContextLoader(FakeSupabase({"lab_escalations": [{
        "id": "e1", "user_id": OTHER, "biomarker_id": "potassium",
        "value_canonical": 7.0, "operator": "=", "unit": "mmol/L",
        "severity": "critical", "message": "Potassium is critically high.",
        "acknowledged_at": None, "created_at": "2026-10-11T07:00:00+00:00",
    }]}))

    assert loader.open_lab_escalations(USER)["items"] == []
