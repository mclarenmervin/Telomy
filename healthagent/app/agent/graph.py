from datetime import datetime, timedelta, timezone
from typing import TypedDict

from langgraph.graph import END, START, StateGraph

from app.agent.guardrails import apply_guardrails
from app.agent.narration import narrate, narrate_check_in
from app.agent.persist import save_prediction
from app.analytics.check_in import CHECK_IN_PREFIX, CheckIn, evaluate_check_in
from app.analytics.event_analysis import BASELINE_DAYS, analyze_event
from app.common.logging_config import get_logger, log_context
from app.common.timeparse import parse_ts

logger = get_logger(__name__)

# An event the user (or the detector) has not closed yet. `ended`, `expired` and
# `rejected` all stop the check-in timer.
OPEN_STATUSES = frozenset({"started", "confirmed"})


class AgentState(TypedDict, total=False):
    user_id: str
    event_id: str
    status: str
    now: str | None
    event: dict | None
    kind: str
    analysis: dict
    summary: str
    check_in: CheckIn | None
    guardrail_flags: list[str]


def build_agent(loader, llm, supabase):
    def load_event(state: AgentState) -> dict:
        return {"event": loader.load_event(state["user_id"], state["event_id"])}

    def route(state: AgentState) -> str:
        context = log_context(user_id=state["user_id"], event_id=state["event_id"])
        event = state.get("event")
        if event is None:
            logger.warning(f"event not found for user, skipping {context}")
            return "end"
        status = state["status"]
        if status == "in_progress":
            # The timer fires on a schedule, so the event may have been closed
            # between scheduling and promotion. Checking the row, not the job,
            # is what makes that race harmless.
            if event.get("status") not in OPEN_STATUSES:
                logger.info(
                    f"event no longer open, dropping check-in {context} "
                    f"event_status={event.get('status')}"
                )
                return "end"
            return "check_in"
        route_for = {"started": "acknowledge", "ended": "analyze"}.get(status)
        if route_for is None:
            logger.info(f"status not handled yet, skipping {context} status={status}")
            return "end"
        return route_for

    def _now(state: AgentState) -> datetime:
        return parse_ts(state.get("now")) or datetime.now(timezone.utc)

    def check_in(state: AgentState) -> dict:
        event = state["event"]
        start = parse_ts(event["started_at"])
        now = _now(state)
        readings = loader.load_readings(state["user_id"], start, now)
        others = loader.load_other_events(
            state["user_id"], state["event_id"], start - timedelta(days=BASELINE_DAYS)
        )
        analysis = analyze_event(readings, start, now, others)
        fired = evaluate_check_in(
            analysis,
            elapsed_seconds=(now - start).total_seconds(),
            already_sent=loader.sent_check_in_reasons(state["user_id"], state["event_id"]),
        )
        if fired is None:
            return {"analysis": analysis, "check_in": None}
        return {
            "kind": f"{CHECK_IN_PREFIX}{fired.reason}",
            "analysis": analysis,
            "check_in": fired,
        }

    def route_check_in(state: AgentState) -> str:
        if state.get("check_in") is None:
            logger.info(
                "nothing to say mid-event "
                f"{log_context(user_id=state['user_id'], event_id=state['event_id'])}"
            )
            return "end"
        return "narrate_check_in"

    def narrate_check_in_node(state: AgentState) -> dict:
        return {
            "summary": narrate_check_in(
                llm, state["event"]["event_type"], state["check_in"], state["analysis"]
            )
        }

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
        start = parse_ts(event["started_at"])
        end = parse_ts(event.get("ended_at")) or start
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
    graph.add_node("check_in", check_in)
    graph.add_node("narrate", narrate_node)
    graph.add_node("narrate_check_in", narrate_check_in_node)
    graph.add_node("guardrails", guardrails)
    graph.add_node("persist", persist)

    graph.add_edge(START, "load_event")
    graph.add_conditional_edges(
        "load_event",
        route,
        {
            "acknowledge": "acknowledge",
            "analyze": "analyze",
            "check_in": "check_in",
            "end": END,
        },
    )
    graph.add_edge("acknowledge", "persist")
    graph.add_edge("analyze", "narrate")
    graph.add_conditional_edges(
        "check_in",
        route_check_in,
        {"narrate_check_in": "narrate_check_in", "end": END},
    )
    graph.add_edge("narrate", "guardrails")
    graph.add_edge("narrate_check_in", "guardrails")
    graph.add_edge("guardrails", "persist")
    graph.add_edge("persist", END)
    return graph.compile()
