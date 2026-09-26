import pytest

from app.agent.llm import OpenAILLM, build_llm
from app.common.config import Settings


def settings(**overrides):
    base = dict(
        supabase_url="https://x.supabase.co",
        supabase_service_key="k",
        webhook_secret="s",
        redis_url="redis://localhost:6379/0",
        queue_name="q",
    )
    base.update(overrides)
    return Settings(**base)


def test_no_key_means_no_llm():
    assert build_llm(settings()) is None


def test_openai_key_builds_openai_llm():
    llm = build_llm(settings(openai_api_key="sk-test", llm_model="gpt-4.1"))

    assert isinstance(llm, OpenAILLM)


def test_unknown_provider_fails_fast():
    with pytest.raises(ValueError):
        build_llm(settings(llm_provider="bedrock"))
