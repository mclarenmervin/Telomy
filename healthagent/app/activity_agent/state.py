from dataclasses import dataclass

from langchain.agents.middleware import AgentState


@dataclass(frozen=True)
class ActivityContext:
    """Per-job runtime context. `user_id` is set once at entry and never mutated."""

    user_id: str
    session_id: str
    display_name: str | None = None


class ActivityState(AgentState):
    session: dict
    past_sessions: list
    profile: dict
    safety_facts: list
    previous_report: dict | None
    analysis: dict
    insights: list
    data_gaps: list
    report: dict
    guardrail_flags: list
    tool_numbers: list
