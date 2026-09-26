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
