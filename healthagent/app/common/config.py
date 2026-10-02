import os
from dataclasses import dataclass, field

MODEL_OVERRIDE_PREFIX = "LLM_MODEL_"


@dataclass(frozen=True)
class Settings:
    supabase_url: str
    supabase_service_key: str
    webhook_secret: str
    redis_url: str
    queue_name: str
    llm_provider: str = "openai"
    openai_api_key: str | None = None
    llm_model: str = "gpt-4o-mini"
    llm_base_url: str | None = None
    aws_region: str | None = None
    # Per-purpose model choices, e.g. LLM_MODEL_NARRATION=gpt-4o-mini picks a
    # cheaper model for narration while the activity agent keeps the default.
    llm_model_overrides: dict[str, str] = field(default_factory=dict)
    supabase_db_url: str | None = None
    activity_queue_name: str = "activity:realtime"
    max_llm_calls: int = 2
    max_tool_calls: int = 8
    wall_clock_seconds: int = 60


def _model_overrides() -> dict[str, str]:
    return {
        key[len(MODEL_OVERRIDE_PREFIX) :].lower(): value
        for key, value in os.environ.items()
        if key.startswith(MODEL_OVERRIDE_PREFIX) and value
    }


def get_settings() -> Settings:
    return Settings(
        supabase_url=os.environ["SUPABASE_URL"],
        supabase_service_key=os.environ["SUPABASE_SERVICE_KEY"],
        webhook_secret=os.environ["WEBHOOK_SECRET"],
        redis_url=os.environ.get("REDIS_URL", "redis://localhost:6379/0"),
        queue_name=os.environ.get("QUEUE_NAME", "events:realtime"),
        llm_provider=os.environ.get("LLM_PROVIDER", "openai"),
        openai_api_key=os.environ.get("OPENAI_API_KEY") or None,
        llm_model=os.environ.get("LLM_MODEL", "gpt-4o-mini"),
        llm_base_url=os.environ.get("LLM_BASE_URL") or None,
        aws_region=os.environ.get("AWS_REGION") or None,
        llm_model_overrides=_model_overrides(),
        supabase_db_url=os.environ.get("SUPABASE_DB_URL") or None,
        activity_queue_name=os.environ.get("ACTIVITY_QUEUE_NAME", "activity:realtime"),
        max_llm_calls=int(os.environ.get("MAX_LLM_CALLS", "2")),
        max_tool_calls=int(os.environ.get("MAX_TOOL_CALLS", "8")),
        wall_clock_seconds=int(os.environ.get("WALL_CLOCK_SECONDS", "60")),
    )
