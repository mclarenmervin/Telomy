import pytest
from app.common.config import get_settings


def test_get_settings_reads_env(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_KEY", "service-key")
    monkeypatch.setenv("WEBHOOK_SECRET", "shh")
    monkeypatch.setenv("REDIS_URL", "redis://localhost:6379/0")
    monkeypatch.setenv("QUEUE_NAME", "events:realtime")

    settings = get_settings()

    assert settings.supabase_url == "https://x.supabase.co"
    assert settings.supabase_service_key == "service-key"
    assert settings.webhook_secret == "shh"
    assert settings.redis_url == "redis://localhost:6379/0"
    assert settings.queue_name == "events:realtime"


def test_get_settings_missing_var_raises(monkeypatch):
    monkeypatch.delenv("SUPABASE_URL", raising=False)
    with pytest.raises(KeyError):
        get_settings()


def test_llm_settings_default_to_openai_without_key(monkeypatch):
    for key, val in {
        "SUPABASE_URL": "https://x.supabase.co",
        "SUPABASE_SERVICE_KEY": "k",
        "WEBHOOK_SECRET": "s",
    }.items():
        monkeypatch.setenv(key, val)
    for name in ("OPENAI_API_KEY", "LLM_MODEL", "LLM_PROVIDER"):
        monkeypatch.delenv(name, raising=False)

    settings = get_settings()

    assert settings.llm_provider == "openai"
    assert settings.openai_api_key is None
    assert settings.llm_model == "gpt-4o-mini"


def test_llm_settings_read_from_env(monkeypatch):
    for key, val in {
        "SUPABASE_URL": "https://x.supabase.co",
        "SUPABASE_SERVICE_KEY": "k",
        "WEBHOOK_SECRET": "s",
        "OPENAI_API_KEY": "sk-test",
        "LLM_MODEL": "gpt-4.1",
        "LLM_PROVIDER": "bedrock",
    }.items():
        monkeypatch.setenv(key, val)

    settings = get_settings()

    assert settings.openai_api_key == "sk-test"
    assert settings.llm_model == "gpt-4.1"
    assert settings.llm_provider == "bedrock"


def test_settings_expose_db_url_and_budgets(monkeypatch):
    for key, value in {
        "SUPABASE_URL": "https://x.supabase.co",
        "SUPABASE_SERVICE_KEY": "k",
        "WEBHOOK_SECRET": "s",
        "SUPABASE_DB_URL": "postgresql://u:p@h:5432/db",
    }.items():
        monkeypatch.setenv(key, value)
    settings = get_settings()
    assert settings.supabase_db_url == "postgresql://u:p@h:5432/db"
    assert settings.activity_queue_name == "activity:realtime"
    assert settings.max_llm_calls == 3
    assert settings.max_tool_calls == 8
    assert settings.wall_clock_seconds == 60


def test_db_url_is_none_when_unset(monkeypatch):
    for key in ("SUPABASE_URL", "SUPABASE_SERVICE_KEY", "WEBHOOK_SECRET"):
        monkeypatch.setenv(key, "x")
    monkeypatch.delenv("SUPABASE_DB_URL", raising=False)
    assert get_settings().supabase_db_url is None
