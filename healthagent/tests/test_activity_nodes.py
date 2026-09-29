from types import SimpleNamespace

from app.activity_agent.nodes import (
    ALLOWED_ACTIVITY_TYPES,
    analyze_node,
    insights_node,
    make_load_context,
    make_load_session,
    route_after_load,
)
from app.activity_agent.prompts import build_system_prompt
from app.activity_agent.state import ActivityContext
from app.common.context_loader import ContextLoader
from tests.fakes import FakeSupabase

USER, OTHER = "user-1", "user-2"
SESSION = {
    "id": "s1",
    "user_id": USER,
    "activity_type": "running",
    "started_at": "2026-09-29T06:00:00+00:00",
    "duration_seconds": 1800,
    "summary": {"heartRate": 142},
    "samples": [{"heartRate": 142}] * 60,
}


def _runtime(user_id=USER, session_id="s1"):
    return SimpleNamespace(context=ActivityContext(user_id=user_id, session_id=session_id))


def test_row_is_reread_and_a_user_mismatch_yields_nothing():
    """Review Focus 4: never trust the payload's user_id."""
    loader = ContextLoader(FakeSupabase({"activity_sessions": [SESSION]}))
    load = make_load_session(loader)

    assert load({}, _runtime())["session"]["id"] == "s1"
    assert load({}, _runtime(user_id=OTHER))["session"] == {}
    assert route_after_load({"session": {}}) == "stop"


def test_samples_come_from_the_row_not_the_payload():
    loader = ContextLoader(FakeSupabase({"activity_sessions": [SESSION]}))
    stale = {"session": {"samples": [{"heartRate": 999}] * 3}}
    out = make_load_session(loader)(stale, _runtime())
    assert len(out["session"]["samples"]) == 60
    assert out["session"]["samples"][0]["heartRate"] == 142


def test_accidental_tap_is_stopped():
    short = dict(SESSION, id="s2", duration_seconds=5)
    loader = ContextLoader(FakeSupabase({"activity_sessions": [short]}))
    out = make_load_session(loader)({}, _runtime(session_id="s2"))
    assert route_after_load(out) == "stop"


def test_unknown_activity_type_is_stopped():
    weird = dict(SESSION, id="s3", activity_type="teleporting")
    loader = ContextLoader(FakeSupabase({"activity_sessions": [weird]}))
    out = make_load_session(loader)({}, _runtime(session_id="s3"))
    assert route_after_load(out) == "stop"
    assert "running" in ALLOWED_ACTIVITY_TYPES
    assert "yoga" in ALLOWED_ACTIVITY_TYPES


def test_a_good_session_continues():
    loader = ContextLoader(FakeSupabase({"activity_sessions": [SESSION]}))
    assert route_after_load(make_load_session(loader)({}, _runtime())) == "continue"


def test_load_context_distinguishes_empty_from_unconfigured():
    loader = ContextLoader(FakeSupabase({"activity_sessions": [SESSION], "meals": []}))
    out = make_load_context(loader)({"session": SESSION}, _runtime())
    gaps = {g["source"]: g["status"] for g in out["data_gaps"]}
    assert gaps["documents"] == "unconfigured"
    assert gaps["past_sessions"] == "empty"


def test_load_context_reads_the_display_name_into_state():
    """Pre-flight ruling: the name must reach the prompt via state, not frozen context."""
    db = FakeSupabase(
        {
            "activity_sessions": [SESSION],
            "user_preferences": [{"user_id": USER, "profile": {"name": "Asha"}}],
        }
    )
    out = make_load_context(ContextLoader(db))({"session": SESSION}, _runtime())
    assert out["profile"]["name"] == "Asha"


def test_analyze_then_insights_populate_state():
    past = [{"duration_seconds": 1800, "summary": {"heartRate": 150}}] * 3
    analyzed = analyze_node({"session": SESSION, "past_sessions": past})
    assert analyzed["analysis"]["score"] is not None
    out = insights_node(analyzed)
    assert isinstance(out["insights"], list)
    assert all({"id", "section", "fact"} <= set(i) for i in out["insights"])


def test_prompt_uses_the_name_from_state_and_never_raw_samples():
    state = {
        "session": SESSION,
        "profile": {"name": "Asha"},
        "analysis": {
            "metrics": [],
            "data_quality": "full",
            "duration_seconds": 1800,
            "score": None,
            "baseline": None,
        },
        "insights": [],
        "data_gaps": [],
    }
    prompt = build_system_prompt(state, ActivityContext(USER, "s1"))
    assert "Asha" in prompt
    assert "samples" not in prompt.lower()
    assert "recordedAt" not in prompt


def test_prompt_falls_back_to_context_name_then_to_unknown():
    base = {"session": SESSION, "analysis": {}, "insights": [], "data_gaps": []}
    assert "Ravi" in build_system_prompt(base, ActivityContext(USER, "s1", display_name="Ravi"))
    assert "unknown" in build_system_prompt(base, ActivityContext(USER, "s1")).lower()


def test_prompt_offers_duration_in_minutes_not_only_seconds():
    """Raw seconds make the model write "lasted 1800 seconds", which reads badly."""
    state = {
        "session": SESSION,
        "profile": {},
        "analysis": {"duration_seconds": 1800, "metrics": [], "data_quality": "full"},
        "insights": [],
        "data_gaps": [],
    }
    prompt = build_system_prompt(state, ActivityContext(USER, "s1"))
    assert '"duration_minutes": 30' in prompt
    assert "minutes" in prompt.lower()
