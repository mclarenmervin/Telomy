from langchain_core.utils.function_calling import convert_to_openai_tool

from types import SimpleNamespace

from app.activity_agent.state import ActivityContext
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


def test_the_expected_ten_tools_are_present():
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
        # F4. Without these the biological age is computed, stored, rendered on
        # one screen and invisible to the agent -- which is exactly how F3's
        # extraction came to be correct in Postgres and absent from the app.
        "get_biological_age",
        "get_epigenetic_clocks",
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


# ── Biological age and epigenetic clocks ─────────────────────────────────────

def _tools_for(tables):
    return {t.name: t for t in build_tools(ContextLoader(FakeSupabase(tables)))}


def _runtime(user_id):
    """The identity a tool reads from state. It is never a model argument."""
    return SimpleNamespace(
        context=ActivityContext(user_id=user_id, session_id="s1")
    )


def test_the_biological_age_tool_reads_the_stored_snapshot():
    """Not a recomputation. The agent quotes the number on the user's screen,
    or a chart and a sentence disagree -- the defect this layer exists to close.
    """
    tool = _tools_for({"score_snapshots": [{
        "user_id": "u1", "score_kind": "biological_age", "as_of_date": "2026-06-15",
        "value": 43.2, "drivers": [], "missing_inputs": [], "data_quality": "full",
        "model_version": "biological-age-phenoage-levine-2018-v1",
        "ranges_version": "global.v1", "timezone": "UTC",
        "inputs_hash": "sha256:a", "computed_at": "2026-06-16T03:00:00",
    }]})["get_biological_age"]

    out = tool.func(_runtime("u1"))

    assert out["items"][0]["value"] == 43.2


def test_the_biological_age_tool_takes_no_score_kind_from_the_model():
    """It answers one question. A `kind` parameter would let the model ask for
    a score the tool's docstring says nothing about how to narrate."""
    sent = convert_to_openai_tool(
        _tools()["get_biological_age"]
    )["function"]["parameters"].get("properties", {})

    assert "kind" not in sent
    assert "score_kind" not in sent


def test_the_epigenetic_tool_returns_the_provider_with_the_value():
    tool = _tools_for({"epigenetic_results": [{
        "user_id": "u1", "clock": "horvath", "value": 41.3, "unit": "years",
        "provider": "TruDiagnostic", "collected_at": "2026-03-01T00:00:00+00:00",
        "source": "third_party",
    }]})["get_epigenetic_clocks"]

    out = tool.func(_runtime("u1"))

    assert out["items"][0]["provider"] == "TruDiagnostic"
    assert out["items"][0]["source"] == "third_party"


def test_both_docstrings_tell_the_model_not_to_interpret():
    """The catalog is unreviewed, so the agent may state these numbers and must
    not grade them -- the same discipline get_lab_results already carries. And
    an epigenetic clock is someone else's measurement, which the model must say
    rather than presenting it as ours."""
    bio = _tools()["get_biological_age"].description.lower()
    clocks = _tools()["get_epigenetic_clocks"].description.lower()

    assert "do not" in bio or "never" in bio
    assert "null" in bio or "unknown" in bio
    assert "third-party" in clocks or "third party" in clocks
    assert "never" in clocks or "do not" in clocks
