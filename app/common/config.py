import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    supabase_url: str
    supabase_service_key: str
    webhook_secret: str
    redis_url: str
    queue_name: str
    anthropic_api_key: str | None = None
    llm_model: str = "claude-sonnet-5"


def get_settings() -> Settings:
    return Settings(
        supabase_url=os.environ["SUPABASE_URL"],
        supabase_service_key=os.environ["SUPABASE_SERVICE_KEY"],
        webhook_secret=os.environ["WEBHOOK_SECRET"],
        redis_url=os.environ.get("REDIS_URL", "redis://localhost:6379/0"),
        queue_name=os.environ.get("QUEUE_NAME", "events:realtime"),
        anthropic_api_key=os.environ.get("ANTHROPIC_API_KEY") or None,
        llm_model=os.environ.get("LLM_MODEL", "claude-sonnet-5"),
    )
