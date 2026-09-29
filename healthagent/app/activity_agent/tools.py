"""Tools for the activity agent.

Two invariants, both load-bearing:
  * no tool takes an identity argument — `user_id` comes from `ToolRuntime.context`
  * every model-supplied number is clamped before it reaches a query
"""

from langchain.tools import ToolRuntime, tool

from app.activity_agent.state import ActivityContext
from app.analytics.activity_analysis import analyze_activity

MAX_DAYS = 365
MAX_LIMIT = 50


def clamp(value, low: int, high: int) -> int:
    try:
        value = int(value)
    except (TypeError, ValueError):
        return low
    return max(low, min(high, value))


def build_tools(loader) -> list:
    @tool
    def get_past_sessions(
        runtime: ToolRuntime[ActivityContext],
        activity_type: str | None = None,
        limit: int = 5,
        window_days: int = 90,
    ) -> dict:
        """Aggregated past activity sessions for the current user.

        Pass activity_type=None to span all activity types. Never returns raw samples.
        """
        return loader.past_activity_sessions(
            runtime.context.user_id,
            activity_type,
            limit=clamp(limit, 1, MAX_LIMIT),
            window_days=clamp(window_days, 1, MAX_DAYS),
        )

    @tool
    def get_logs(
        runtime: ToolRuntime[ActivityContext],
        kind: str,
        days: int = 30,
        limit: int = 20,
    ) -> dict:
        """Entries the user logged, by kind.

        kind is one of: lab_results, therapy_sessions, genetic_records, environment_logs,
        meals, workouts, hydration_logs, plans, progress_checkins, consultations,
        timeline_events. Use this to explain a session from what happened around it.
        """
        try:
            return loader.logs(
                runtime.context.user_id,
                kind,
                days=clamp(days, 1, MAX_DAYS),
                limit=clamp(limit, 1, MAX_LIMIT),
            )
        except ValueError as exc:
            return {"status": "error", "items": [], "reason": str(exc)}

    @tool
    def get_measurements(
        runtime: ToolRuntime[ActivityContext],
        measurement_type: str,
        days: int = 30,
        limit: int = 100,
    ) -> dict:
        """Typed body or vital measurements, e.g. weight, restingHeartRate, sleepDuration."""
        return loader.measurements(
            runtime.context.user_id,
            measurement_type,
            days=clamp(days, 1, MAX_DAYS),
            limit=clamp(limit, 1, MAX_LIMIT),
        )

    @tool
    def get_daily_snapshot(runtime: ToolRuntime[ActivityContext], days: int = 7) -> dict:
        """Daily ring summaries (sleep, readiness) around the session."""
        return loader.daily_snapshots(runtime.context.user_id, days=clamp(days, 1, 31))

    @tool
    def get_documents(
        runtime: ToolRuntime[ActivityContext],
        kind: str | None = None,
        limit: int = 5,
    ) -> dict:
        """Uploaded documents such as lab reports.

        A status of 'unconfigured' means document storage is not set up — it does NOT
        mean the user has no documents. Never tell the user they have none in that case.
        """
        return loader.documents(runtime.context.user_id, kind, limit=clamp(limit, 1, MAX_LIMIT))

    @tool
    def get_past_reports(runtime: ToolRuntime[ActivityContext], limit: int = 3) -> dict:
        """Previous activity reports, for continuity with advice already given."""
        return loader.past_activity_reports(runtime.context.user_id, limit=clamp(limit, 1, 10))

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
        )["items"]
        return {"status": "ok", "items": [analyze_activity(session, past)]}

    return [
        get_past_sessions,
        get_logs,
        get_measurements,
        get_daily_snapshot,
        get_documents,
        get_past_reports,
        compare_window,
    ]
