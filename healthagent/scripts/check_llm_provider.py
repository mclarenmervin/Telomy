"""Check whether an OpenAI-compatible provider can run the activity agent.

The agent needs two things beyond plain chat: tool calling, and strict structured
output for the nested `Narrative` schema. Providers vary on the second one, so test
rather than assume.

    LLM_BASE_URL=https://api.groq.com/openai/v1 \
    OPENAI_API_KEY=gsk_... \
    LLM_MODEL=openai/gpt-oss-120b \
    python scripts/check_llm_provider.py
"""
import os
import sys

from langchain_core.tools import tool
from langchain_openai import ChatOpenAI

from app.activity_agent.report import Narrative

model_name = os.environ.get("LLM_MODEL", "openai/gpt-oss-120b")
base_url = os.environ.get("LLM_BASE_URL") or None
llm = ChatOpenAI(
    model=model_name,
    api_key=os.environ["OPENAI_API_KEY"],
    base_url=base_url,
    temperature=0,
    timeout=60,
)
print(f"model    : {model_name}")
print(f"base_url : {base_url or 'https://api.openai.com/v1 (default)'}\n")

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


check("plain chat", plain)
check("tool calling", tool_calling)
check("structured output (nested Narrative schema)", structured)

print()
if failures:
    print("NOT USABLE as-is. Failed:", ", ".join(failures))
    print("If only structured output failed, the agent can still run by dropping")
    print("response_format and parsing JSON by hand - ask before doing that, it")
    print("weakens the contract the report builder relies on.")
    sys.exit(1)
print("All three capabilities present - this provider can run the activity agent.")
