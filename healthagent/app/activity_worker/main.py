import redis

from app.activity_agent.agent import build_activity_agent
from app.activity_worker.handlers import process_activity_job
from app.common.checkpointer import build_checkpointer
from app.common.config import get_settings
from app.common.context_loader import ContextLoader
from app.common.logging_config import configure_logging, get_logger
from app.common.queue import JobQueue
from app.common.supabase_client import get_supabase_client
from app.common.thresholds import describe, get_thresholds

logger = get_logger(__name__)


def process_one(queue, agent, timeout: int = 5, wall_clock_seconds: int = 60) -> bool:
    try:
        job = queue.dequeue(timeout=timeout)
    except Exception:
        logger.exception("dequeue failed, will retry next tick")
        return False
    if job is None:
        return False
    process_activity_job(job, agent, wall_clock_seconds, queue=queue)
    return True


def run() -> None:
    configure_logging()
    settings = get_settings()
    # socket_timeout must exceed BRPOP's blocking timeout, as in the events worker.
    redis_client = redis.Redis.from_url(settings.redis_url, socket_timeout=30)
    queue = JobQueue(redis_client, settings.activity_queue_name)
    supabase = get_supabase_client()
    agent = build_activity_agent(
        ContextLoader(supabase), supabase, settings, build_checkpointer(settings)
    )
    logger.info(
        "activity worker started "
        f"llm={'on' if settings.openai_api_key else 'off (deterministic prose)'} "
        f"model={settings.llm_model} lane={settings.activity_queue_name}"
    )
    logger.info(f"severity thresholds: {describe(get_thresholds())}")
    while True:
        process_one(queue, agent, wall_clock_seconds=settings.wall_clock_seconds)


if __name__ == "__main__":
    run()
