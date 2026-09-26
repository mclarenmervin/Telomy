from datetime import datetime, timedelta
from typing import TypedDict

from langgraph.graph import END, START, StateGraph

from app.agent.guardrails import apply_guardrails
from app.agent.narration import narrate
from app.agent.persist import save_prediction
from app.analytics.event_analysis import BASELINE_DAYS, analyze_event
from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)


class AgentState(TypedDict, total=False):
    user_id: str
    event_id: str
    status: str
    event: dict | None
    kind: str
    analysis: dict
    summary: str
    guardrail_flags: list[str]


def build_agent(loader, llm, supabase):
    def load_event(state: AgentState) -> dict:
        return {"event": loader.load_event(state["user_id"], state["event_id"])}

    def route(state: AgentState) -> str:
        context = log_context(user_id=state["user_id"], event_id=state["event_id"])
        if state.get("event") is None:
            logger.warning(f"event not found for user, skipping {context}")
            return "end"
        route_for = {"started": "acknowledge", "ended": "analyze"}.get(state["status"])
        if route_for is None:
            logger.info(f"status not handled yet, skipping {context} status={state['status']}")
            return "end"
        return route_for

    def acknowledge(state: AgentState) -> dict:
        event_type = state["event"]["event_type"]
        return {
            "kind": "ack",
            "analysis": {},
            "summary": (
                f"Got it, I'm tracking your {event_type} session. "
                "I'll share what I see when you stop."
            ),
            "guardrail_flags": [],
        }

    def analyze(state: AgentState) -> dict:
        event = state["event"]
        start = datetime.fromisoformat(event["started_at"])
        end = datetime.fromisoformat(event["ended_at"]) if event.get("ended_at") else start
        readings = loader.load_readings(state["user_id"], start, end)
        others = loader.load_other_events(
            state["user_id"], state["event_id"], start - timedelta(days=BASELINE_DAYS)
        )
        return {"kind": "analysis", "analysis": analyze_event(readings, start, end, others)}

    def narrate_node(state: AgentState) -> dict:
        return {"summary": narrate(llm, state["event"]["event_type"], state["analysis"])}

    def guardrails(state: AgentState) -> dict:
        text, flags = apply_guardrails(state["summary"], state["analysis"])
        return {"summary": text, "guardrail_flags": flags}

    def persist(state: AgentState) -> dict:
        save_prediction(
            supabase,
            {
                "user_id": state["user_id"],
                "event_id": state["event_id"],
                "kind": state["kind"],
                "summary": state["summary"],
                "analysis": state["analysis"],
                "data_quality": state["analysis"].get("data_quality", "none"),
                "guardrail_flags": state["guardrail_flags"],
            },
        )
        logger.info(
            f"prediction saved {log_context(user_id=state['user_id'], event_id=state['event_id'])}"
            f" kind={state['kind']}"
        )
        return {}

    graph = StateGraph(AgentState)
    graph.add_node("load_event", load_event)
    graph.add_node("acknowledge", acknowledge)
    graph.add_node("analyze", analyze)
    graph.add_node("narrate", narrate_node)
    graph.add_node("guardrails", guardrails)
    graph.add_node("persist", persist)

    graph.add_edge(START, "load_event")
    graph.add_conditional_edges(
        "load_event",
        route,
        {"acknowledge": "acknowledge", "analyze": "analyze", "end": END},
    )
    graph.add_edge("acknowledge", "persist")
    graph.add_edge("analyze", "narrate")
    graph.add_edge("narrate", "guardrails")
    graph.add_edge("guardrails", "persist")
    graph.add_edge("persist", END)
    return graph.compile()
