"""The concierge's tools.

Two things are being asserted, and the second is the whole reason this file is
short: the concierge reads the user's data through the *same* tools the activity
agent uses, and it reads the stored score rather than computing one. A third
caller is a third caller, not a third implementation.
"""

from types import SimpleNamespace

from langchain_core.utils.function_calling import convert_to_openai_tool

from app.activity_agent.tools import build_tools as build_activity_tools
from app.agent.data_tools import build_data_tools
from app.common.context_loader import ContextLoader
from app.concierge.state import ConciergeContext
from app.concierge.tools import build_concierge_tools
from tests.fakes import FakeSupabase


def _tools(tables=None):
    return {
        t.name: t
        for t in build_concierge_tools(ContextLoader(FakeSupabase(tables or {})))
    }


def _runtime(user_id="u1"):
    """Identity comes from the runtime context, never from the model — the same
    rule the activity agent's tools follow, for the same reason."""
    return SimpleNamespace(context=ConciergeContext(user_id=user_id))


def test_the_data_tools_are_the_activity_agents_tools():
    """Not a copy. If these two sets ever drift, a chart, a report and a
    conversation start disagreeing about the same user."""
    loader = ContextLoader(FakeSupabase({}))
    shared = {t.name for t in build_data_tools(loader)}
    activity = {t.name for t in build_activity_tools(loader)}

    assert shared < activity
    # The only thing the activity agent has that is not shared: it is about one
    # session, and the concierge is not in a session.
    assert activity - shared == {"compare_window"}


def test_a_shared_tool_serves_a_context_with_no_session():
    """The structural proof that the shared tools never needed a session. They
    are annotated for the activity agent's context and read exactly one field
    from it."""
    tool = _tools({"health_measurements": [{
        "user_id": "u1", "measurement_type": "weight", "value": 71.2,
        "unit": "kg", "recorded_at": "2026-10-01T06:00:00+00:00",
    }]})["get_measurements"]

    out = tool.func(_runtime("u1"), "weight")

    assert out["status"] == "ok"
    assert out["items"][0]["value"] == 71.2


def test_another_users_data_is_not_reachable_from_a_context():
    """The isolation mechanism, exercised rather than described: the tool reads
    `user_id` from the context and the model has no way to name a different
    one."""
    tool = _tools({"health_measurements": [{
        "user_id": "u2", "measurement_type": "weight", "value": 71.2,
        "unit": "kg", "recorded_at": "2026-10-01T06:00:00+00:00",
    }]})["get_measurements"]

    out = tool.func(_runtime("u1"), "weight")

    assert out["items"] == []


def test_no_tool_exposes_an_identity_argument():
    forbidden = {"user_id", "userId", "uid", "id", "runtime", "context"}
    for name, tool in _tools().items():
        sent = convert_to_openai_tool(tool)["function"]["parameters"].get("properties", {})
        assert not forbidden & set(sent), f"{name} exposes identity to the model"


def test_readiness_comes_from_the_stored_snapshot():
    """The number the user is looking at, not one recomputed a second later
    from slightly different data. That is the dual-math defect with extra
    steps, and F2 spent a phase closing it."""
    tool = _tools({"score_snapshots": [{
        "user_id": "u1", "score_kind": "readiness", "as_of_date": "2026-10-10",
        "value": 68, "drivers": [{"name": "HRV", "score": 72.0, "weight": 0.22}],
        "missing_inputs": [], "data_quality": "full",
        "model_version": "readiness-v2", "ranges_version": None,
        "timezone": "Asia/Kolkata", "inputs_hash": "sha256:abc",
        "computed_at": "2026-10-11T03:00:00",
    }]})["get_readiness"]

    out = tool.func(_runtime("u1"))

    assert out["items"][0]["value"] == 68
    assert out["items"][0]["model_version"] == "readiness-v2"
    assert out["items"][0]["as_of_date"] == "2026-10-10"


def test_readiness_takes_no_score_kind_from_the_model():
    sent = convert_to_openai_tool(
        _tools()["get_readiness"]
    )["function"]["parameters"].get("properties", {})

    assert sent == {}


def test_the_readiness_docstring_says_the_number_is_the_stored_one():
    description = _tools()["get_readiness"].description.lower()

    assert "stored" in description or "snapshot" in description
    assert "as_of_date" in description
    assert "null" in description or "unknown" in description


def test_there_is_no_session_comparison_tool():
    """`compare_window` compares one activity session against a history window.
    A conversation has no session to compare, and a tool that quietly answered
    about some other session would be worse than its absence."""
    assert "compare_window" not in _tools()


def test_no_tool_exposes_an_unreviewed_draft():
    """F5's boundary, restated for the new caller. The agent holds service-role
    credentials and bypasses RLS by design, so the enforcement on our side is
    that no tool and no loader method reaches `clinical_drafts`."""
    names = set(_tools())

    assert not {n for n in names if "draft" in n or "review" in n}
    assert "get_clinical_insights" in names


def test_every_tool_has_a_description():
    for name, tool in _tools().items():
        assert tool.description, f"{name} has no description for the model to read"


def test_the_concierge_reads_correlations_rather_than_computing_them():
    """The same function the Correlations screen's endpoint calls. A third
    caller is a third caller, not a third implementation."""
    from datetime import datetime, timedelta, timezone

    now = datetime.now(timezone.utc)
    rows = []
    for day in range(40):
        swing = (day % 7) * 3
        for mtype, value in (("hrv", 40 + swing), ("restingHeartRate", 70 - swing)):
            rows.append({
                "user_id": "u1", "measurement_type": mtype, "value": value,
                "recorded_at": (now - timedelta(days=day)).isoformat(),
            })

    tool = _tools({
        "health_measurements": rows,
        "meals": [], "workouts": [], "hydration_logs": [],
    })["get_correlations"]

    out = tool.func(_runtime("u1"))

    assert [r["pair_id"] for r in out["reported"]] == ["hrv__resting_heart_rate"]
    # Unsigned catalog: the association goes out, the explanation does not.
    assert out["reported"][0]["mechanism"] is None


def test_the_correlation_window_a_model_asks_for_is_clamped():
    """Every model-supplied number is clamped before it reaches a query."""
    tool = _tools({
        "health_measurements": [], "meals": [], "workouts": [], "hydration_logs": [],
    })["get_correlations"]

    assert tool.func(_runtime(), days=99999)["window_days"] == 90
    assert tool.func(_runtime(), days=-5)["window_days"] == 30
