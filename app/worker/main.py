import redis
from typing import Any
from app.common.config import get_settings
from app.common.logging_config import configure_logging, get_logger
from app.common.queue import JobQueue
from app.common.supabase_client import get_supabase_client
from app.worker.handlers import process_event_job

logger = get_logger(__name__)


def process_one(queue: Any, supabase: Any, timeout: int = 5) -> bool:
    try:
        job = queue.dequeue(timeout=timeout)
    except Exception:
        logger.exception("dequeue failed, will retry next tick")
        return False
    if job is None:
        return False
    process_event_job(job, supabase)
    return True


def run() -> None:
    configure_logging()
    settings = get_settings()
    # socket_timeout must comfortably exceed BRPOP's blocking timeout (below),
    # or the client can give up waiting for Redis's reply right as it arrives.
    redis_client = redis.Redis.from_url(settings.redis_url, socket_timeout=30)
    queue = JobQueue(redis_client, settings.queue_name)
    supabase = get_supabase_client()
    logger.info("worker started")
    while True:
        process_one(queue, supabase)


if __name__ == "__main__":
    run()
