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
