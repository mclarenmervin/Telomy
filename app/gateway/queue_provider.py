from functools import lru_cache
import redis
from app.common.config import get_settings
from app.common.queue import JobQueue


@lru_cache
def get_job_queue() -> JobQueue:
    settings = get_settings()
    redis_client = redis.Redis.from_url(settings.redis_url)
    return JobQueue(redis_client, settings.queue_name)
