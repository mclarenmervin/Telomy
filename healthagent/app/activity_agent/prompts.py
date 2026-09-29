"""Dynamic system prompt.

Ordering matters for prompt caching: stable instructions first, per-session facts last,
so the cacheable prefix is as long as possible.
"""

import json

ROLE = """You are a health and fitness analyst writing a short report about one finished \
activity session.

Rules you must follow:
- Every number you state must come from the COMPUTED FACTS below. Never calculate, \
estimate, or infer a figure yourself; if you need a different comparison, call the \
compare_window tool.
- Base all advice on the DETERMINED FINDINGS below. Do not invent training or health \
advice beyond them.
- You are not a clinician. Never diagnose, never discuss medication or dosage, never \
prescribe treatment.
- A data source marked "unconfigured" means we could not look it up. It does NOT mean \
the user has none of that data, and you must not say they do.
- If data quality is "none", do not make confident physiological claims at all.
- Write in second person, plainly, no emoji, no headings inside section bodies.
- Express duration in minutes, never in seconds.

Produce a headline plus these sections, in this order: what_happened, what_changed, \
what_went_well, watch_outs, improve. Two or three sentences each."""


def _display_name(state, context) -> str | None:
    """State first: the name is read from the database one node after the frozen
    ActivityContext is built, so the context cannot carry it at runtime."""
    profile = state.get("profile") or {}
    from_state = profile.get("displayName") or profile.get("name")
    return from_state or getattr(context, "display_name", None)


def build_system_prompt(state, context) -> str:
    analysis = state.get("analysis") or {}
    name = _display_name(state, context)
    greeting = f"The user's name is {name}." if name else "The user's name is unknown."

    seconds = analysis.get("duration_seconds")
    facts = {
        "activity_type": (state.get("session") or {}).get("activity_type"),
        "duration_minutes": round(seconds / 60) if seconds else None,
        "duration_seconds": seconds,
        "data_quality": analysis.get("data_quality"),
        "score": analysis.get("score"),
        "baseline": analysis.get("baseline"),
        "metrics": analysis.get("metrics"),
        "history_used": analysis.get("history_used"),
    }
    previous = state.get("previous_report") or {}
    return "\n\n".join(
        [
            ROLE,
            greeting,
            f"COMPUTED FACTS (the only numbers you may use):\n{json.dumps(facts, default=str)}",
            "DETERMINED FINDINGS (the only advice you may give):\n"
            f"{json.dumps(state.get('insights') or [], default=str)}",
            f"UNAVAILABLE SOURCES:\n{json.dumps(state.get('data_gaps') or [], default=str)}",
            f"PREVIOUS REPORT HEADLINE: {previous.get('summary') or 'none'}",
        ]
    )
