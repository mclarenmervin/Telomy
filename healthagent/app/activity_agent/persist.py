from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)


def save_activity_report(supabase, user_id, session_id, report, flags) -> None:
    """One upsert at the end. `event_id` holds the triggering row's id."""
    supabase.table("predictions").upsert(
        {
            "user_id": user_id,
            "event_id": session_id,
            "kind": "activity_summary",
            "summary": report["headline"],
            "analysis": report,
            "data_quality": report.get("data_quality", "none"),
            "guardrail_flags": flags,
        },
        on_conflict="event_id,kind",
    ).execute()
    logger.info(f"activity report saved {log_context(user_id=user_id, session_id=session_id)}")
