"""The one model-calling part of the concierge.

A prebuilt `create_agent`, so tools, budgets and retries are framework-provided
rather than hand-rolled — the same choice the activity agent made, for the same
reason.

There is no graph here and no sub-agent. The deterministic steps live in
`turn.py` as ordinary Python, because every one of them is a rule rather than a
decision and wrapping a rule in an LLM adds latency and error for nothing.

Unlike the activity agent there is no `response_format`: a conversational reply
*is* the text, and a schema over it would only give the model somewhere to put
prose we then concatenate. The report needs sections because a screen renders
them; a message does not.
"""

from app.common.llm import get_model
from app.common.logging_config import get_logger
from app.concierge.prompts import build_system_prompt
from app.concierge.state import ConciergeContext, ConciergeState
from app.concierge.tools import build_concierge_tools

logger = get_logger(__name__)

#: Its own LLM purpose, so the concierge can be pointed at a different provider
#: from the activity agent. It needs tool calling but no response schema, which
#: is a combination more providers support than the activity agent's.
CONCIERGE = "concierge"


def budget_middleware(settings) -> list:
    """The caps, read from settings and never from a literal.

    Both are needed and neither is sufficient. A model that keeps calling tools
    spends money without ever producing a reply; a model called repeatedly
    spends it without touching a tool. `wall_clock_seconds` is the third cap
    and is applied as the model's own timeout in `get_model`.

    `exit_behavior="end"` rather than raising: an exhausted budget must still
    produce something for the person waiting, and whatever the model managed to
    say goes through every check in `turn.py` as usual.
    """
    from langchain.agents.middleware import (
        ModelCallLimitMiddleware,
        ToolCallLimitMiddleware,
    )

    return [
        ModelCallLimitMiddleware(run_limit=settings.max_llm_calls, exit_behavior="end"),
        ToolCallLimitMiddleware(run_limit=settings.max_tool_calls, exit_behavior="end"),
    ]


def build_narrator(loader, settings):
    """The compiled agent, or None when no model is configured.

    None is a supported state and not a failure: the turn answers with an
    honest "I can't answer in my own words right now" and the user's data is
    still on its own screens. A missing key degrades the wording rather than
    breaking the feature.
    """
    model = get_model(settings, CONCIERGE)
    if model is None:
        logger.info("no model configured for the concierge; chat will say so")
        return None

    from langchain.agents import create_agent
    from langchain.agents.middleware import ModelRetryMiddleware, dynamic_prompt

    @dynamic_prompt
    def prompt(request):
        return build_system_prompt(request.state, request.runtime.context)

    return create_agent(
        model=model,
        tools=build_concierge_tools(loader),
        middleware=[
            prompt,
            *budget_middleware(settings),
            ModelRetryMiddleware(max_retries=1, on_failure="continue"),
        ],
        state_schema=ConciergeState,
        context_schema=ConciergeContext,
    )
