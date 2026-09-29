from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout

from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)

MAX_ATTEMPTS = 2


def process_activity_job(job: dict, agent, wall_clock_seconds: int, queue=None) -> None:
    user_id, session_id = job.get("user_id"), job.get("session_id")
    if not user_id or not session_id:
        logger.warning(f"malformed activity job, skipping: {job}")
        return
    attempt = job.get("attempt", 1)
    context = log_context(user_id=user_id, session_id=session_id)

    def _retry(reason: str) -> None:
        """Re-enqueue once. Supabase already got its 202, so it will never retry for us."""
        if queue is None or attempt >= MAX_ATTEMPTS:
            logger.error(f"activity job abandoned after {attempt} attempt(s) [{reason}] {context}")
            return
        queue.enqueue({"user_id": user_id, "session_id": session_id, "attempt": attempt + 1})
        logger.warning(f"activity job requeued (attempt {attempt + 1}) [{reason}] {context}")

    # A deadline the worker actually enforces: the graph runs on a helper thread so a hung
    # model or database call cannot stall the single-threaded lane indefinitely.
    executor = ThreadPoolExecutor(max_workers=1)
    try:
        future = executor.submit(
            agent.invoke,
            {"messages": []},
            context={"user_id": user_id, "session_id": session_id},
            config={"configurable": {"thread_id": session_id}, "recursion_limit": 25},
        )
        try:
            future.result(timeout=wall_clock_seconds)
            logger.info(f"activity job processed {context}")
        except FutureTimeout:
            logger.error(
                f"activity job exceeded {wall_clock_seconds}s deadline, releasing worker {context}"
            )
            _retry("deadline exceeded")
        except Exception:
            # A single bad session must never take the worker down.
            logger.exception(f"activity job failed {context}")
            _retry("exception")
    finally:
        # Do not block on an abandoned thread; it is orphaned deliberately.
        executor.shutdown(wait=False)
