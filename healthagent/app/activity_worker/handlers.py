from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)


def process_activity_job(job: dict, agent, wall_clock_seconds: int) -> None:
    user_id, session_id = job.get("user_id"), job.get("session_id")
    if not user_id or not session_id:
        logger.warning(f"malformed activity job, skipping: {job}")
        return
    context = log_context(user_id=user_id, session_id=session_id)
    try:
        agent.invoke(
            {"messages": []},
            context={"user_id": user_id, "session_id": session_id},
            config={"configurable": {"thread_id": session_id}, "recursion_limit": 25},
        )
        logger.info(f"activity job processed {context}")
    except Exception:
        # A single bad session must never take the worker down.
        logger.exception(f"activity job failed {context}")
