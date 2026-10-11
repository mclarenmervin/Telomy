"""The process-wide concierge.

Built once rather than per request: the narrator holds a configured chat model,
and constructing one on every message would add latency to the one path in this
product where a human is actually waiting.

Chat bypasses the job queue, which CLAUDE.md settled — routing a waiting person
behind ten thousand weekly reports makes the feature unusable. It is the one
place the gateway does more than acknowledge and enqueue, and it is safe
because the expensive parts are capped: `max_chat_turns_per_day` before the
model runs, `max_llm_calls` and `max_tool_calls` inside it, and
`wall_clock_seconds` on the model itself.
"""

from functools import lru_cache

from app.common.config import get_settings
from app.common.context_loader import ContextLoader
from app.common.supabase_client import get_supabase_client
from app.concierge.agent import build_narrator
from app.concierge.turn import Concierge


@lru_cache
def get_concierge() -> Concierge:
    settings = get_settings()
    supabase = get_supabase_client()
    loader = ContextLoader(supabase)
    return Concierge(
        loader=loader,
        supabase=supabase,
        settings=settings,
        narrator=build_narrator(loader, settings),
    )
