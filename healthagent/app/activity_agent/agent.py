"""Graph assembly.

A deterministic StateGraph with exactly one model-calling node. The narration step is a
prebuilt `create_agent`, so tools, budgets, retries and structured output are all
framework-provided.
"""

from langgraph.graph import END, START, StateGraph

from app.activity_agent import nodes
from app.activity_agent.persist import save_activity_report
from app.activity_agent.prompts import build_system_prompt
from app.activity_agent.report import (
    build_report,
    fallback_narrative,
    verify_numbers,
)
from app.activity_agent.state import ActivityContext, ActivityState
from app.agent.guardrails import apply_guardrails
from app.common.logging_config import get_logger

logger = get_logger(__name__)


def _build_narrator(loader, settings):
    """None when no API key is configured — the graph then uses deterministic prose."""
    if not getattr(settings, "openai_api_key", None):
        return None

    from langchain.agents import create_agent
    from langchain.agents.middleware import (
        ModelCallLimitMiddleware,
        ModelRetryMiddleware,
        ToolCallLimitMiddleware,
        dynamic_prompt,
    )
    from langchain_openai import ChatOpenAI

    from app.activity_agent.report import Narrative
    from app.activity_agent.tools import build_tools

    @dynamic_prompt
    def prompt(request):
        return build_system_prompt(request.state, request.runtime.context)

    return create_agent(
        model=ChatOpenAI(
            model=settings.llm_model,
            api_key=settings.openai_api_key,
            temperature=0,
            timeout=settings.wall_clock_seconds,
        ),
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
        narrative = None
        if narrator is not None:
            try:
                result = narrator.invoke(
                    {
                        "messages": [
                            {"role": "user", "content": "Write the report for this session."}
                        ],
                        **{k: state[k] for k in ("session", "analysis", "insights",
                                                 "data_gaps", "profile", "previous_report")
                           if k in state},
                    },
                    context=runtime.context,
                )
                narrative = result.get("structured_response")
            except Exception:
                logger.exception("narration failed, falling back to deterministic prose")
        if narrative is None:
            narrative = fallback_narrative(analysis, insights)
        return {
            "report": build_report(analysis, insights, narrative, state.get("data_gaps") or [])
        }

    def verify(state) -> dict:
        report, flags = verify_numbers(state["report"], state["analysis"])
        return {"report": report, "guardrail_flags": flags}

    def guardrails(state) -> dict:
        report = state["report"]
        flags = list(state.get("guardrail_flags") or [])
        # Reuse the existing deterministic medical-safety rules unchanged.
        analysis_for_rules = {
            "metrics": {m["key"]: {"during_mean": m["value"]} for m in report.get("metrics", [])}
        }
        for section in report["sections"]:
            text, section_flags = apply_guardrails(section["body"], analysis_for_rules)
            section["body"] = text
            flags.extend(f for f in section_flags if f not in flags)
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
