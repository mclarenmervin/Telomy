import os
from dataclasses import dataclass, field

# Settings a purpose may override, longest first so BASE_URL wins over its prefix.
OVERRIDABLE = ("BASE_URL", "API_KEY", "PROVIDER", "MODEL")


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
    # Per-purpose overrides, e.g. LLM_PROVIDER_NARRATION=groq runs the simple
    # narration call on Groq while the activity agent — which needs tools and a
    # response schema in one request, and so cannot use Groq — stays on OpenAI.
    # Shape: {"narration": {"provider": "groq", "model": "..."}}
    llm_overrides: dict[str, dict[str, str]] = field(default_factory=dict)
    supabase_db_url: str | None = None
    activity_queue_name: str = "activity:realtime"
    max_llm_calls: int = 3
    max_tool_calls: int = 8
    wall_clock_seconds: int = 60
    check_in_interval_seconds: int = 600
    check_in_max_seconds: int = 28800
    delayed_queue_name: str = "events:delayed"


def _llm_overrides() -> dict[str, dict[str, str]]:
    """Collect LLM_<SETTING>_<PURPOSE> env vars into {purpose: {setting: value}}."""
    overrides: dict[str, dict[str, str]] = {}
    for key, value in os.environ.items():
        if not key.startswith("LLM_") or not value:
            continue
        for setting in OVERRIDABLE:
            prefix = f"LLM_{setting}_"
            if key.startswith(prefix):
                purpose = key[len(prefix) :].lower()
                overrides.setdefault(purpose, {})[setting.lower()] = value
                break
    return overrides


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
        llm_overrides=_llm_overrides(),
        supabase_db_url=os.environ.get("SUPABASE_DB_URL") or None,
        activity_queue_name=os.environ.get("ACTIVITY_QUEUE_NAME", "activity:realtime"),
        max_llm_calls=int(os.environ.get("MAX_LLM_CALLS", "3")),
        max_tool_calls=int(os.environ.get("MAX_TOOL_CALLS", "8")),
        wall_clock_seconds=int(os.environ.get("WALL_CLOCK_SECONDS", "60")),
        check_in_interval_seconds=int(os.environ.get("CHECK_IN_INTERVAL_SECONDS", "600")),
        check_in_max_seconds=int(os.environ.get("CHECK_IN_MAX_SECONDS", "28800")),
        delayed_queue_name=os.environ.get("DELAYED_QUEUE_NAME", "events:delayed"),
    )
