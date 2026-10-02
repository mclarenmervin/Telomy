import pytest

from app.common.config import Settings
from app.common.llm import (
    get_activity_model,
    get_model,
    get_narration_model,
    model_name_for,
)


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


def test_no_key_means_no_model():
    assert get_model(settings()) is None


def test_openai_key_builds_a_langchain_chat_model():
    model = get_model(settings(openai_api_key="sk-test", llm_model="gpt-4.1"))

    assert type(model).__name__ == "ChatOpenAI"


def test_model_exposes_the_agent_interface():
    """create_agent needs these; a raw vendor SDK client has neither."""
    model = get_model(settings(openai_api_key="sk-test"))

    assert hasattr(model, "bind_tools")
    assert hasattr(model, "with_structured_output")


def test_base_url_points_at_an_openai_compatible_provider():
    model = get_model(
        settings(
            openai_api_key="gsk-test",
            llm_model="openai/gpt-oss-120b",
            llm_base_url="https://api.groq.com/openai/v1",
        )
    )

    assert "groq.com" in str(model.openai_api_base)


def test_unknown_provider_fails_fast():
    with pytest.raises(ValueError):
        get_model(settings(llm_provider="nonesuch", openai_api_key="k"))


def test_missing_provider_package_names_what_to_install():
    with pytest.raises(ValueError, match="langchain"):
        get_model(settings(llm_provider="groq", openai_api_key="k"))


def test_bedrock_does_not_require_an_api_key():
    """Bedrock authenticates with AWS SigV4, so no key must not mean no model."""
    with pytest.raises(ValueError, match="langchain"):
        get_model(settings(llm_provider="bedrock_converse", aws_region="us-east-1"))


def test_purpose_override_selects_a_different_model():
    cfg = settings(
        openai_api_key="sk-test",
        llm_model="gpt-5.4-mini",
        llm_model_overrides={"narration": "gpt-4o-mini"},
    )

    assert model_name_for(cfg, "narration") == "gpt-4o-mini"
    assert model_name_for(cfg, "activity") == "gpt-5.4-mini"
    assert model_name_for(cfg) == "gpt-5.4-mini"


def test_purpose_helpers_use_their_own_lane():
    cfg = settings(
        openai_api_key="sk-test",
        llm_model="gpt-5.4-mini",
        llm_model_overrides={"narration": "gpt-4o-mini"},
    )

    assert get_narration_model(cfg).model_name == "gpt-4o-mini"
    assert get_activity_model(cfg).model_name == "gpt-5.4-mini"
