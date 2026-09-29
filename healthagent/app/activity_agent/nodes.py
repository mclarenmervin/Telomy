"""Deterministic nodes. No model is called anywhere in this module."""

from app.analytics.activity_analysis import analyze_activity, is_plausible_session
from app.analytics.insight_rules import evaluate
from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)

ALLOWED_ACTIVITY_TYPES = frozenset(
    {"running", "walking", "cycling", "swimming", "strength", "yoga", "other"}
)


def make_load_session(loader):
    def load_session(state, runtime) -> dict:
        ctx = runtime.context
        # Authoritative re-read: the webhook payload is untrusted, and `samples` can be
        # megabytes. Scoping by user_id means a mismatched payload finds nothing.
        session = loader.activity_session(ctx.user_id, ctx.session_id)
        if session is None:
            logger.warning(
                "session not found or not this user's "
                f"{log_context(user_id=ctx.user_id, session_id=ctx.session_id)}"
            )
            return {"session": {}}
        return {"session": session}

    return load_session


def route_after_load(state) -> str:
    session = state.get("session") or {}
    if not session:
        return "stop"
    if session.get("activity_type") not in ALLOWED_ACTIVITY_TYPES:
        logger.warning(f"unknown activity_type={session.get('activity_type')}, stopping")
        return "stop"
    if not is_plausible_session(session):
        logger.info(f"implausible duration={session.get('duration_seconds')}, stopping")
        return "stop"
    return "continue"


def make_load_context(loader):
    def load_context(state, runtime) -> dict:
        ctx = runtime.context
        session = state["session"]
        past = loader.past_activity_sessions(
            ctx.user_id, session.get("activity_type"), exclude_id=ctx.session_id
        )
        profile = loader.user_profile(ctx.user_id)
        safety = loader.safety_facts(ctx.user_id)
        reports = loader.past_activity_reports(ctx.user_id, limit=1)
        documents = loader.documents(ctx.user_id)

        gaps = []
        for source, result in (
            ("past_sessions", past),
            ("profile", profile),
            ("safety_facts", safety),
            ("past_reports", reports),
            ("documents", documents),
        ):
            if result["status"] != "ok":
                gap = {"source": source, "status": result["status"]}
                if "reason" in result:
                    gap["reason"] = result["reason"]
                gaps.append(gap)

        return {
            "past_sessions": past["items"],
            "profile": (profile["items"][0].get("profile") if profile["items"] else {}) or {},
            "safety_facts": safety["items"],
            "previous_report": reports["items"][0] if reports["items"] else None,
            "data_gaps": gaps,
        }

    return load_context


def analyze_node(state) -> dict:
    return {"analysis": analyze_activity(state["session"], state.get("past_sessions") or [])}


def insights_node(state) -> dict:
    found = evaluate(state["analysis"])
    return {"insights": [{"id": i.id, "section": i.section, "fact": i.fact} for i in found]}
