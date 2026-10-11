"""Building the concierge's narrator.

Budget caps are the thing worth testing here. Agents loop, and a chat turn is
the easiest place in this product to spend hundreds of dollars unnoticed — so
the caps must come from settings rather than from a literal somebody can forget
to change, and a missing model must degrade the wording rather than break the
feature.
"""

from app.common.context_loader import ContextLoader
from app.concierge.agent import budget_middleware, build_narrator
from tests.fakes import FakeSupabase, make_settings


def test_without_a_model_there_is_no_narrator():
    """A supported state, not a failure: the turn falls back to an honest
    "I can't answer in my own words right now", exactly as both existing agents
    degrade when no key is configured."""
    loader = ContextLoader(FakeSupabase({}))

    assert build_narrator(loader, make_settings(openai_api_key=None)) is None


def test_the_caps_come_from_settings():
    limits = {m.name: m for m in budget_middleware(
        make_settings(max_llm_calls=2, max_tool_calls=5)
    )}

    assert limits["ModelCallLimitMiddleware"].run_limit == 2
    assert limits["ToolCallLimitMiddleware"].run_limit == 5


def test_a_cap_ends_the_turn_rather_than_raising():
    """An exhausted budget must produce a reply, not a 500. The turn then takes
    whatever the model had said by that point and runs every check on it as
    usual."""
    for middleware in budget_middleware(make_settings()):
        assert middleware.exit_behavior == "end"


def test_there_is_a_cap_on_both_model_calls_and_tool_calls():
    """Either one alone is a loop: a model that keeps calling tools spends
    money without producing a reply, and a model called repeatedly spends it
    without touching a tool."""
    names = {m.name for m in budget_middleware(make_settings())}

    assert "ModelCallLimitMiddleware" in names
    assert "ToolCallLimitMiddleware" in names
