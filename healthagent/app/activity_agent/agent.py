"""Graph assembly.

A deterministic StateGraph with exactly one model-calling node. The narration step is a
prebuilt `create_agent`, so tools, budgets, retries and structured output are all
framework-provided.
"""

import re

from langgraph.graph import END, START, StateGraph

from app.activity_agent import nodes
from app.activity_agent.persist import save_activity_report
from app.activity_agent.prompts import build_system_prompt
from app.activity_agent.report import (
    build_report,
    collect_tool_numbers,
    fallback_narrative,
    verify_numbers,
)
from app.activity_agent.state import ActivityContext, ActivityState
from app.analytics.severity import ATTENTION, NORMAL, URGENT, annotate
from app.common.thresholds import get_thresholds
from app.agent.guardrails import ESCALATION_LINE, apply_guardrails
from app.common.logging_config import get_logger

logger = get_logger(__name__)

# Exercise-specific danger thresholds. The event agent's HEART_RATE_HIGH = 150 describes
# a resting-ish context; a mean of 150-175 bpm is ordinary for a tempo run, so reusing it
# would put a chest-pain warning on most hard workouts.
SPO2_DANGER_MIN = 90.0
HEART_RATE_DANGER_MAX = 200.0


# Reassurance that happens to contain a concern word. "Nothing flagged" is the
# canonical way a report says everything is fine, and it would otherwise satisfy
# the check below — the exact case this guard exists to catch.
_REASSURANCE = re.compile(
    r"\b(?:nothing|no|none|not)\b[^.]{0,30}?"
    r"\b(?:flagged|flag|concerns?|unusual|watch|worry|worrying|issues?|problems?)\b",
    re.I,
)

# Words a report must use somewhere when Python has raised a flag. Deliberately broad:
# the check exists to catch a wholly reassuring narrative, not to police phrasing.
_CONCERN_WORDS = re.compile(
    r"\b(?:watch|watching|flag|flagged|concern\w*|checked|check|unusual|outside|"
    r"lower than|higher than|dipped|elevated|practitioner|consultation|doctor)\b",
    re.I,
)


def _acknowledges_concern(report: dict) -> bool:
    """Whether a report with a raised severity actually says so."""
    if report.get("severity", NORMAL) not in (ATTENTION, URGENT):
        return True
    texts = [report.get("headline") or ""]
    texts += [s.get("body") or "" for s in report.get("sections") or []]
    # Strip negated reassurance first, so "nothing flagged" cannot pass as acknowledgement.
    return any(_CONCERN_WORDS.search(_REASSURANCE.sub(" ", text)) for text in texts)


def _exercise_danger(analysis) -> bool:
    """True only for readings that are alarming *during exercise*."""
    aggregates = analysis.get("aggregates") or {}
    spo2 = aggregates.get("spo2") or {}
    heart_rate = aggregates.get("heartRate") or {}
    spo2_min = spo2.get("min")
    hr_max = heart_rate.get("max")
    return (spo2_min is not None and spo2_min < SPO2_DANGER_MIN) or (
        hr_max is not None and hr_max > HEART_RATE_DANGER_MAX
    )


def _guard_headline(headline: str, analysis) -> tuple[str, list[str]]:
    """The headline reaches predictions.summary and is the most-read text, so it gets the
    same deterministic language check as the bodies — but never the escalation append,
    which belongs in a section."""
    # Empty metrics: language rules only, no value-triggered escalation.
    return apply_guardrails(headline, {"metrics": {}})


def _build_narrator(loader, settings):
    """None when no model is configured — the graph then uses deterministic prose."""
    from app.common.llm import get_activity_model

    model = get_activity_model(settings)
    if model is None:
        return None

    from langchain.agents import create_agent
    from langchain.agents.middleware import (
        ModelCallLimitMiddleware,
        ModelRetryMiddleware,
        ToolCallLimitMiddleware,
        dynamic_prompt,
    )

    from app.activity_agent.report import Narrative
    from app.activity_agent.tools import build_tools

    @dynamic_prompt
    def prompt(request):
        return build_system_prompt(request.state, request.runtime.context)

    return create_agent(
        model=model,
        tools=build_tools(loader),
        middleware=[
            prompt,
            ModelCallLimitMiddleware(run_limit=settings.max_llm_calls, exit_behavior="end"),
            ToolCallLimitMiddleware(run_limit=settings.max_tool_calls, exit_behavior="end"),
            ModelRetryMiddleware(max_retries=1, on_failure="continue"),
        ],
        response_format=Narrative,
        state_schema=ActivityState,
        context_schema=ActivityContext,
    )


def build_activity_agent(loader, supabase, settings, checkpointer=None):
    narrator = _build_narrator(loader, settings)

    def narrate(state, runtime) -> dict:
        analysis = state["analysis"]
        insights = state.get("insights") or []
        # The prompt needs severity BEFORE narration; build_report recomputes it after.
        _, severity = annotate(
            analysis.get("metrics") or [], state.get("profile") or {}, get_thresholds()
        )
        state = {**state, "severity": severity}
        narrative = None
        tool_numbers = set()
        if narrator is not None:
            try:
                result = narrator.invoke(
                    {
                        "messages": [
                            {"role": "user", "content": "Write the report for this session."}
                        ],
                        **{
                            k: state[k]
                            for k in (
                                "session", "analysis", "insights", "data_gaps",
                                "profile", "previous_report", "safety_facts", "severity",
                            )
                            if k in state
                        },
                    },
                    context=runtime.context,
                )
                narrative = result.get("structured_response")
                tool_numbers = collect_tool_numbers(result.get("messages"))
            except Exception:
                logger.exception("narration failed, falling back to deterministic prose")
        used_fallback = narrative is None
        if used_fallback:
            narrative = fallback_narrative(analysis, insights)
        report = build_report(
            analysis, insights, narrative, state.get("data_gaps") or [],
            profile=state.get("profile") or {},
        )
        flags = []
        if used_fallback:
            # A missing key or an exhausted budget must not look like a normal report.
            flags.append("narration_incomplete")
            if report["data_quality"] == "full":
                report["data_quality"] = "partial"
        return {
            "report": report,
            "guardrail_flags": flags,
            "tool_numbers": sorted(tool_numbers),
        }

    def verify(state) -> dict:
        report, new_flags = verify_numbers(
            state["report"], state["analysis"], state.get("tool_numbers") or []
        )
        flags = list(state.get("guardrail_flags") or [])
        flags.extend(f for f in new_flags if f not in flags)
        return {"report": report, "guardrail_flags": flags}

    def guardrails(state) -> dict:
        report = state["report"]
        flags = list(state.get("guardrail_flags") or [])

        # Language rules over every section AND the headline. Empty metrics are passed so
        # the reused module never appends its own escalation per section.
        for section in report["sections"]:
            text, section_flags = apply_guardrails(section["body"], {"metrics": {}})
            section["body"] = text
            flags.extend(f for f in section_flags if f not in flags)

        safe_headline, headline_flags = _guard_headline(report["headline"], state["analysis"])
        if headline_flags:
            # Replace rather than publish sanitised boilerplate as the list-view line.
            safe_headline = fallback_narrative(state["analysis"], []).headline
        report["headline"] = safe_headline
        flags.extend(f for f in headline_flags if f not in flags)

        if not _acknowledges_concern(report):
            # A reassuring narrative against a raised flag is worse than no narrative.
            deterministic = fallback_narrative(state["analysis"], state.get("insights") or [])
            report["headline"] = deterministic.headline
            by_id = {s.id: s for s in deterministic.sections}
            for section in report["sections"]:
                if section["id"] in by_id:
                    section["body"] = by_id[section["id"]].body
            if "severity_mismatch" not in flags:
                flags.append("severity_mismatch")

        # Escalate once, in the section where a warning belongs — not five times.
        if _exercise_danger(state["analysis"]):
            watch = next(s for s in report["sections"] if s["id"] == "watch_outs")
            watch["body"] = f"{watch['body']} {ESCALATION_LINE}".strip()
            if "escalation" not in flags:
                flags.append("escalation")

        return {"report": report, "guardrail_flags": flags}

    def persist(state, runtime) -> dict:
        save_activity_report(
            supabase,
            runtime.context.user_id,
            runtime.context.session_id,
            state["report"],
            state.get("guardrail_flags") or [],
        )
        return {}

    graph = StateGraph(ActivityState, context_schema=ActivityContext)
    graph.add_node("load_session", nodes.make_load_session(loader))
    graph.add_node("load_context", nodes.make_load_context(loader))
    graph.add_node("analyze", nodes.analyze_node)
    graph.add_node("insights", nodes.insights_node)
    graph.add_node("narrate", narrate)
    graph.add_node("verify", verify)
    graph.add_node("guardrails", guardrails)
    graph.add_node("persist", persist)

    graph.add_edge(START, "load_session")
    graph.add_conditional_edges(
        "load_session", nodes.route_after_load, {"continue": "load_context", "stop": END}
    )
    graph.add_edge("load_context", "analyze")
    graph.add_edge("analyze", "insights")
    graph.add_edge("insights", "narrate")
    graph.add_edge("narrate", "verify")
    graph.add_edge("verify", "guardrails")
    graph.add_edge("guardrails", "persist")
    graph.add_edge("persist", END)
    return graph.compile(checkpointer=checkpointer)
