"""Queue consumer for score recomputes. Same shape as the other workers."""

import redis

from app.common.config import get_settings
from app.common.logging_config import configure_logging, get_logger
from app.common.queue import JobQueue
from app.common.supabase_client import get_supabase_client
from app.score_worker.handlers import process_score_job

logger = get_logger(__name__)


def process_one(queue, supabase, timeout: int = 5) -> bool:
    try:
        job = queue.dequeue(timeout=timeout)
    except Exception:
        logger.exception("dequeue failed, will retry next tick")
        return False
    if job is None:
        return False
    process_score_job(job, supabase)
    return True


def run() -> None:
    configure_logging()
    settings = get_settings()
    # socket_timeout must exceed BRPOP's blocking timeout, as in the other workers.
    redis_client = redis.Redis.from_url(settings.redis_url, socket_timeout=30)
    queue = JobQueue(redis_client, settings.score_queue_name)
    supabase = get_supabase_client()
    logger.info(f"score worker started lane={settings.score_queue_name}")
    while True:
        process_one(queue, supabase)


if __name__ == "__main__":
    run()
