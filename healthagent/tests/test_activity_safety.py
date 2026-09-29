"""Fixes from the whole-branch review: escalation, safety facts, headline, fallback."""

from types import SimpleNamespace

from app.activity_agent.agent import build_activity_agent
from app.activity_agent.prompts import build_system_prompt
from app.activity_agent.state import ActivityContext
from app.common.context_loader import ContextLoader
from tests.fakes import FakeSupabase

USER = "user-1"


def _session(hr, **over):
    base = {
        "id": "s1", "user_id": USER, "activity_type": "running",
        "started_at": "2026-09-29T06:00:00+00:00", "duration_seconds": 1800,
        "summary": {"heartRate": hr}, "samples": [{"heartRate": hr, "spo2": 97}] * 60,
    }
    base.update(over)
    return base


PAST = [
    {"id": f"p{i}", "user_id": USER, "activity_type": "running",
     "started_at": f"2026-09-2{i}T06:00:00+00:00", "duration_seconds": 1800,
     "summary": {"heartRate": 150}}
    for i in range(1, 4)
]
SETTINGS = SimpleNamespace(
    openai_api_key=None, llm_model="x", max_llm_calls=2, max_tool_calls=8,
    wall_clock_seconds=60,
)


def _run(db, session_id="s1"):
    agent = build_activity_agent(ContextLoader(db), db, SETTINGS, checkpointer=None)
    agent.invoke(
        {"messages": []},
        context={"user_id": USER, "session_id": session_id},
        config={"configurable": {"thread_id": session_id}},
    )
    return db.tables["predictions"][0]


def test_a_normal_hard_run_gets_no_chest_pain_warning():
    """Finding 1: mean HR 160 is ordinary for a tempo run, not a medical emergency."""
    db = FakeSupabase({"activity_sessions": [_session(160)] + PAST, "predictions": []})
    row = _run(db)
    bodies = " ".join(s["body"] for s in row["analysis"]["sections"])
    assert "chest pain" not in bodies.lower()
    assert "escalation" not in row["guardrail_flags"]


def test_a_genuinely_dangerous_reading_escalates_exactly_once():
    """Low SpO2 during exercise is a real signal; it must appear once, not five times."""
    session = _session(140)
    session["samples"] = [{"heartRate": 140, "spo2": 84}] * 60
    db = FakeSupabase({"activity_sessions": [session] + PAST, "predictions": []})
    row = _run(db)
    bodies = [s["body"] for s in row["analysis"]["sections"]]
    occurrences = sum("seek medical care" in b.lower() for b in bodies)
    assert occurrences == 1, f"escalation appeared {occurrences} times"
    assert "escalation" in row["guardrail_flags"]


def test_safety_facts_reach_the_prompt():
    """Finding 2: medications are loaded deterministically and must be shown."""
    state = {
        "session": _session(142), "profile": {"name": "Asha"},
        "analysis": {"metrics": [], "data_quality": "full", "duration_seconds": 1800},
        "insights": [], "data_gaps": [],
        "safety_facts": [{"title": "Metformin", "notes": "500mg twice daily", "fields": {}}],
    }
    prompt = build_system_prompt(state, ActivityContext(USER, "s1"))
    assert "Metformin" in prompt
    assert "SAFETY" in prompt.upper()


def test_absent_medications_are_not_reported_as_a_data_gap():
    """Having no medications is not a gap the UI should invite the user to fill."""
    db = FakeSupabase({"activity_sessions": [_session(142)] + PAST, "predictions": []})
    row = _run(db)
    sources = {g["source"] for g in row["analysis"]["data_gaps"]}
    assert "safety_facts" not in sources


def test_the_headline_passes_through_the_medical_guardrails():
    """Finding 3: the headline is the most-seen text and reaches predictions.summary."""
    from app.activity_agent.agent import _guard_headline

    safe, flags = _guard_headline("You likely have an arrhythmia.", {"metrics": []})
    assert "arrhythmia" not in safe.lower()
    assert "diagnosis" in flags


def test_unconfigured_and_empty_are_separated_in_the_prompt():
    """Finding 11: 'we could not look' and 'you have none' need different headings."""
    state = {
        "session": _session(142), "profile": {},
        "analysis": {"metrics": [], "data_quality": "full", "duration_seconds": 1800},
        "insights": [],
        "data_gaps": [
            {"source": "documents", "status": "unconfigured", "reason": "not configured"},
            {"source": "past_sessions", "status": "empty"},
        ],
    }
    prompt = build_system_prompt(state, ActivityContext(USER, "s1"))
    # Anchor on the data-block headings, which are distinct from the ROLE wording.
    unreachable_block = prompt.index("SOURCES WE COULD NOT CHECK")
    empty_block = prompt.index("SOURCES THE USER GENUINELY HAS NO DATA IN")
    assert unreachable_block < empty_block
    assert "documents" in prompt[unreachable_block:empty_block]
    assert "past_sessions" not in prompt[unreachable_block:empty_block]
    assert "past_sessions" in prompt[empty_block:]


def test_the_fallback_path_is_visible_in_the_persisted_row():
    """Finding 10: a missing API key must not look like a normal full-quality report."""
    db = FakeSupabase({"activity_sessions": [_session(142)] + PAST, "predictions": []})
    row = _run(db)  # SETTINGS has openai_api_key=None, so narration falls back
    assert "narration_incomplete" in row["guardrail_flags"]
    assert row["data_quality"] == "partial"
