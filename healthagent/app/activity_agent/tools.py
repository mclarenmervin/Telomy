"""Tools for the activity agent.

The user-scoped tools live in `app/agent/data_tools.py` and are shared with the
concierge — one implementation, several callers. What is left here is the one
tool that only means something inside a session.
"""

from langchain.tools import ToolRuntime, tool

from app.activity_agent.state import ActivityContext
from app.agent.data_tools import MAX_DAYS, MAX_LIMIT, build_data_tools, clamp
from app.analytics.activity_analysis import analyze_activity

__all__ = ["MAX_DAYS", "MAX_LIMIT", "build_tools", "clamp"]


def build_tools(loader) -> list:
    @tool
    def compare_window(runtime: ToolRuntime[ActivityContext], window_days: int = 30) -> dict:
        """Recompute this session's comparison against a different history window.

        Deterministic: all arithmetic happens in Python. Use this instead of calculating
        differences yourself.
        """
        ctx = runtime.context
        session = loader.activity_session(ctx.user_id, ctx.session_id)
        if session is None:
            return {"status": "error", "items": [], "reason": "session not found"}
        past = loader.past_activity_sessions(
            ctx.user_id,
            session.get("activity_type"),
            limit=MAX_LIMIT,
            window_days=clamp(window_days, 1, MAX_DAYS),
            exclude_id=ctx.session_id,
        )["items"]
        return {"status": "ok", "items": [analyze_activity(session, past)]}

    return [*build_data_tools(loader), compare_window]
