"""Check whether an OpenAI-compatible provider can run the activity agent.

The agent needs two things beyond plain chat: tool calling, and strict structured
output for the nested `Narrative` schema. Providers vary on the second one, so test
rather than assume.

    LLM_BASE_URL=https://api.groq.com/openai/v1 \
    OPENAI_API_KEY=gsk_... \
    LLM_MODEL=openai/gpt-oss-120b \
    python scripts/check_llm_provider.py

It builds the model through app/common/llm.py, so it exercises the same code path
the worker does rather than a parallel one that could drift.
"""
import sys

from langchain_core.tools import tool

from app.activity_agent.report import Narrative
from app.common.config import get_settings
from app.common.llm import get_activity_model, model_name_for

# Built the same way the worker builds it, so a pass here means the agent will work.
settings = get_settings()
llm = get_activity_model(settings)
if llm is None:
    sys.exit("no model configured - set OPENAI_API_KEY (or your provider's key)")

print(f"provider : {settings.llm_provider}")
print(f"model    : {model_name_for(settings, 'activity')}")
print(f"base_url : {settings.llm_base_url or 'provider default'}")
print(f"class    : {type(llm).__name__}\n")

failures = []


def check(label, fn):
    try:
        fn()
        print(f"PASS  {label}")
    except Exception as exc:
        print(f"FAIL  {label}\n        {type(exc).__name__}: {str(exc)[:300]}")
        failures.append(label)


def plain():
    assert llm.invoke("Reply with the single word: ok").content


@tool
def past_sessions(limit: int = 3) -> str:
    """Return how many past sessions the user has."""
    return "4 past sessions"


def tool_calling():
    out = llm.bind_tools([past_sessions]).invoke(
        "How many past sessions do I have? Use the tool."
    )
    assert out.tool_calls, "model returned no tool_calls"


def structured():
    # The real schema: a headline plus a list of {id, title, body} objects.
    out = llm.with_structured_output(Narrative).invoke(
        "Write a one-sentence headline and exactly two sections "
        "(ids 'what_happened' and 'what_changed') about a 30 minute cycling session."
    )
    assert out.headline, "empty headline"
    assert len(out.sections) >= 1, "no sections returned"


def real_agent():
    """`create_agent` itself — the only faithful test.

    Checking tools and structured output separately is not enough, and nor is
    `bind_tools().with_structured_output()`: that routes the schema through a
    tool call, while create_agent asks for provider-native JSON mode. Groq
    accepts the former and rejects the latter with "json mode cannot be combined
    with tool/function calling" — which surfaces only as an empty
    structured_response and a silent fall back to deterministic prose.
    """
    from langchain.agents import create_agent

    agent = create_agent(model=llm, tools=[past_sessions], response_format=Narrative)
    result = agent.invoke(
        {"messages": [("human", "Write a headline and one section (id "
                                "'what_happened') about a 30 minute ride.")]}
    )
    if result.get("structured_response") is None:
        last = result["messages"][-1].content if result.get("messages") else ""
        raise AssertionError(f"no structured_response. last message: {str(last)[:300]}")


check("plain chat", plain)
check("tool calling", tool_calling)
check("structured output (nested Narrative schema)", structured)
check("create_agent (tools + structured output together)", real_agent)

print()
if failures:
    print("Failed:", ", ".join(failures))
    if failures == ["create_agent (tools + structured output together)"]:
        print()
        print("This provider cannot run the ACTIVITY agent, which needs tools and a")
        print("response schema in one request. It can still run plain calls, so set")
        print("it per purpose instead:")
        print("    LLM_PROVIDER_NARRATION=groq  LLM_MODEL_NARRATION=...")
        print("leaving the activity agent on a provider that passes this check.")
    sys.exit(1)
print("All capabilities present - this provider can run every agent.")
