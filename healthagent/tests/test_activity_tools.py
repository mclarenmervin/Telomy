from langchain_core.utils.function_calling import convert_to_openai_tool

from app.activity_agent.tools import MAX_DAYS, MAX_LIMIT, build_tools, clamp
from app.common.context_loader import ContextLoader
from tests.fakes import FakeSupabase


def _tools():
    return {t.name: t for t in build_tools(ContextLoader(FakeSupabase({})))}


def test_no_tool_exposes_an_identity_argument():
    """The central isolation guarantee, enforced structurally rather than by convention.

    Asserted against the payload actually sent to the provider, not the internal
    args_schema — the internal schema legitimately carries the injected `runtime`.
    """
    forbidden = {"user_id", "userId", "uid", "id", "runtime", "context"}
    for name, tool in _tools().items():
        sent = convert_to_openai_tool(tool)["function"]["parameters"].get("properties", {})
        leaked = forbidden & set(sent)
        assert not leaked, f"{name} exposes {leaked} to the model"


def test_runtime_is_injected_not_model_supplied():
    """`runtime` exists on the internal schema but never on the model-visible one."""
    tool = _tools()["get_past_sessions"]
    assert "runtime" in tool.args_schema.model_fields
    assert "runtime" not in tool.tool_call_schema.model_json_schema()["properties"]


def test_the_expected_eight_tools_are_present():
    assert set(_tools()) == {
        "get_past_sessions",
        "get_logs",
        "get_measurements",
        "get_daily_snapshot",
        "get_documents",
        # Lab values the user has confirmed. get_documents only says a report
        # exists; without this the agent could name the report and not a single
        # number in it.
        "get_lab_results",
        "get_past_reports",
        "compare_window",
    }


def test_no_tool_accepts_a_user_id():
    """Identity comes from state, never from the model. A tool that took a
    user_id would make cross-tenant access a prompt away."""
    for name, tool in _tools().items():
        schema = convert_to_openai_tool(tool)["function"]
        params = set(schema.get("parameters", {}).get("properties", {}))
        assert "user_id" not in params, name


def test_arguments_are_clamped():
    assert clamp(10**9, 1, MAX_DAYS) == MAX_DAYS
    assert clamp(-5, 1, MAX_LIMIT) == 1
    assert clamp(10, 1, MAX_LIMIT) == 10
    assert clamp("nonsense", 1, MAX_LIMIT) == 1


def test_every_tool_has_a_docstring_description():
    for name, tool in _tools().items():
        assert tool.description, f"{name} has no description for the model to read"
