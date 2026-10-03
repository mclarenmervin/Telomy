"""Fixes from the whole-branch review: escalation, safety facts, headline, fallback."""


from app.activity_agent.agent import build_activity_agent
from app.activity_agent.prompts import build_system_prompt
from app.activity_agent.state import ActivityContext
from app.common.context_loader import ContextLoader
from tests.fakes import FakeSupabase, make_settings

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
SETTINGS = make_settings(openai_api_key=None, llm_model="x")


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
    analysis = row["analysis"]
    bodies = [s["body"] for s in analysis["sections"]]
    # Spec 7.4: the sentence now lives in the escalation block, not in a section body.
    assert sum("seek medical care" in b.lower() for b in bodies) == 0
    assert "seek medical care" in analysis["escalation"]["body"].lower()
    assert analysis["escalation"]["level"] == "urgent"
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


def test_a_congratulatory_report_against_a_raised_flag_is_replaced():
    """A warm persona must not be able to soften an attention finding into nothing."""
    from app.activity_agent.agent import _acknowledges_concern

    glowing = {
        "severity": "attention",
        "headline": "A brilliant session, nothing to worry about.",
        "sections": [{"id": "watch_outs", "title": "Worth watching", "body": "Nothing flagged."}],
        "escalation": {"level": "recommended", "title": "Worth getting checked",
                       "body": "One of your readings moved outside your usual range."},
    }

    assert _acknowledges_concern(glowing) is False


def test_a_report_that_names_the_concern_passes():
    from app.activity_agent.agent import _acknowledges_concern

    honest = {
        "severity": "attention",
        "headline": "Mostly steady, with one thing to flag.",
        "sections": [{"id": "watch_outs", "title": "Worth watching",
                      "body": "Your blood oxygen moved outside your usual range — "
                              "worth having someone look at it."}],
        "escalation": {"level": "recommended", "title": "Worth getting checked", "body": "x"},
    }

    assert _acknowledges_concern(honest) is True


def test_a_normal_report_is_never_treated_as_inconsistent():
    from app.activity_agent.agent import _acknowledges_concern

    plain = {"severity": "normal", "headline": "A steady session.",
             "sections": [{"id": "watch_outs", "title": "Worth watching",
                           "body": "Nothing flagged."}],
             "escalation": {"level": "routine", "title": "Book a consultation", "body": "x"}}

    assert _acknowledges_concern(plain) is True


REASSURING_BUT_COMPARATIVE = [
    "Great work today, Asha. Nothing to worry about here — just keep watching your pacing.",
    "Your heart rate was lower than your recent average. Fantastic progress, nothing to flag.",
    "You hit a new best. Steps were higher than your recent average.",
]


def test_comparative_praise_does_not_count_as_acknowledging_a_flag():
    """Describing a delta is what the prompt asks for in what_changed, so delta
    language must not by itself satisfy the check — otherwise the guard passes
    almost every real narrative and catches only degenerate ones."""
    from app.activity_agent.agent import _acknowledges_concern

    for body in REASSURING_BUT_COMPARATIVE:
        report = {
            "severity": "attention",
            "headline": "A great session.",
            "sections": [
                {"id": "what_changed", "title": "What changed", "body": body},
                {"id": "watch_outs", "title": "Worth watching", "body": "Nothing flagged."},
            ],
        }

        assert _acknowledges_concern(report) is False, body


def test_a_concern_named_in_watch_outs_counts():
    from app.activity_agent.agent import _acknowledges_concern

    report = {
        "severity": "attention",
        "headline": "Mostly steady.",
        "sections": [
            {"id": "what_changed", "title": "What changed",
             "body": "Your heart rate was lower than your recent average."},
            {"id": "watch_outs", "title": "Worth watching",
             "body": "Your blood oxygen dipped outside your usual range — worth getting checked."},
        ],
    }

    assert _acknowledges_concern(report) is True


def test_a_concern_named_only_in_the_headline_counts():
    from app.activity_agent.agent import _acknowledges_concern

    report = {
        "severity": "urgent",
        "headline": "One reading here is worth getting checked.",
        "sections": [{"id": "what_changed", "title": "What changed", "body": "Steady throughout."}],
    }

    assert _acknowledges_concern(report) is True


def test_the_escalation_sentence_appears_exactly_once_through_the_real_graph():
    """Spec 7.4: the line is carried by the escalation block, not ALSO appended to
    watch_outs. Printing it twice reads as a glitch in the one place that must not."""
    from app.agent.guardrails import ESCALATION_LINE

    session = _session(140)
    session["samples"] = [{"heartRate": 140, "spo2": 84}] * 60
    db = FakeSupabase({"activity_sessions": [session] + PAST, "predictions": []})
    row = _run(db)
    analysis = row["analysis"]
    whole = " ".join(
        [analysis["headline"]]
        + [s["body"] for s in analysis["sections"]]
        + [analysis["escalation"]["title"], analysis["escalation"]["body"]]
    )

    assert analysis["severity"] == "urgent"
    assert whole.count(ESCALATION_LINE) == 1, whole


def test_the_graph_replaces_a_dishonest_narrative_and_flags_it():
    """Only _acknowledges_concern was unit-tested; nothing covered the node actually
    swapping the prose. The fixture deliberately includes the comparative what_changed
    text a real report carries, which is what let the bypass through."""
    from app.activity_agent.agent import _acknowledges_concern
    from app.activity_agent.report import build_report, fallback_narrative

    flagged = {"key": "hrv", "value": 32.0, "min": 30, "max": 34,
               "baseline": 50.0, "delta": -18.0, "direction": "worse"}
    analysis = {"activity_type": "cycling", "duration_seconds": 1800, "metrics": [flagged],
                "score": None, "baseline": {}, "data_quality": "full", "history_used": {}}

    dishonest = build_report(analysis, [], fallback_narrative(analysis, []), [])
    dishonest["headline"] = "A brilliant ride, nothing to worry about."
    for section in dishonest["sections"]:
        section["body"] = {
            "what_changed": "Your heart rate was lower than your recent average.",
            "watch_outs": "Nothing flagged.",
        }.get(section["id"], "Great work.")

    assert dishonest["severity"] == "attention"
    assert _acknowledges_concern(dishonest) is False

    replacement = fallback_narrative(analysis, [])
    repaired = build_report(analysis, [], replacement, [])

    assert _acknowledges_concern(repaired) is True
    watch = next(s for s in repaired["sections"] if s["id"] == "watch_outs")
    assert "Nothing flagged" not in watch["body"]
