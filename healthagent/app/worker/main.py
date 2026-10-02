import redis
from typing import Any

from app.common.context_loader import ContextLoader
from app.agent.graph import build_agent
from app.common.llm import get_narration_model
from app.common.config import get_settings
from app.common.logging_config import configure_logging, get_logger
from app.common.queue import JobQueue
from app.common.supabase_client import get_supabase_client
from app.worker.handlers import process_event_job

logger = get_logger(__name__)


def process_one(queue: Any, agent: Any, timeout: int = 5) -> bool:
    try:
        job = queue.dequeue(timeout=timeout)
    except Exception:
        logger.exception("dequeue failed, will retry next tick")
        return False
    if job is None:
        return False
    process_event_job(job, agent)
    return True


def run() -> None:
    configure_logging()
    settings = get_settings()
    # socket_timeout must comfortably exceed BRPOP's blocking timeout (below),
    # or the client can give up waiting for Redis's reply right as it arrives.
    redis_client = redis.Redis.from_url(settings.redis_url, socket_timeout=30)
    queue = JobQueue(redis_client, settings.queue_name)
    supabase = get_supabase_client()
    llm = get_narration_model(settings)
    agent = build_agent(ContextLoader(supabase), llm, supabase)
    logger.info(f"worker started llm={'on' if llm else 'off (fallback summaries)'}")
    while True:
        process_one(queue, agent)


if __name__ == "__main__":
    run()
