"""The one place that decides which chat model to use.

Every model in this codebase is a LangChain `BaseChatModel`. That is not a
preference: `create_agent` requires one, because only a `BaseChatModel` carries
`bind_tools()` and `with_structured_output()`. Routing the older event agent
through the same type means a provider swap is configuration, not code — and it
is why no module imports a vendor SDK directly any more.

Choosing a provider:

    LLM_PROVIDER=openai           LLM_MODEL=gpt-5.4-mini
    LLM_PROVIDER=openai           LLM_MODEL=openai/gpt-oss-120b \\
                                  LLM_BASE_URL=https://api.groq.com/openai/v1
    LLM_PROVIDER=groq             LLM_MODEL=openai/gpt-oss-120b
    LLM_PROVIDER=bedrock_converse LLM_MODEL=anthropic.claude-...  AWS_REGION=...

Groq, Together and local servers speak the OpenAI wire protocol, so pointing
`LLM_BASE_URL` at them needs no extra dependency. The native `groq` and
`bedrock*` providers need `langchain-groq` / `langchain-aws` installed; the
import error names the missing package.

Per-purpose models: `LLM_MODEL_<PURPOSE>` overrides `LLM_MODEL` for one caller,
so narration can run on a cheaper model than the activity agent without a code
change.
"""

from app.common.config import Settings

# Providers that authenticate with an API key. Bedrock is deliberately absent:
# it uses AWS SigV4 (an IAM role or the standard AWS_* credentials), so there is
# no key to check and an unset OPENAI_API_KEY must not disable it.
_API_KEY_PROVIDERS = frozenset({"openai", "groq", "anthropic", "together", "deepseek", "xai"})

NARRATION = "narration"
ACTIVITY = "activity"


def model_name_for(settings: Settings, purpose: str | None = None) -> str:
    """The model this purpose should use, falling back to the default."""
    if purpose:
        return settings.llm_model_overrides.get(purpose, settings.llm_model)
    return settings.llm_model


def _provider_kwargs(settings: Settings, provider: str) -> dict:
    """Provider-specific arguments.

    These genuinely differ — Bedrock takes a region and no key at all — so the
    shape cannot be one fixed signature without breaking when Bedrock is added.
    """
    if provider.startswith("bedrock"):
        return {"region_name": settings.aws_region} if settings.aws_region else {}
    kwargs: dict = {"api_key": settings.openai_api_key}
    # Only OpenAI-compatible endpoints take a base URL; passing it to others errors.
    if settings.llm_base_url and provider == "openai":
        kwargs["base_url"] = settings.llm_base_url
    return kwargs


def get_model(settings: Settings, purpose: str | None = None, **overrides):
    """Return a configured chat model, or None when no credentials are set.

    None is a supported state, not a failure: both agents fall back to
    deterministic prose, which is why a missing key degrades the wording rather
    than breaking the report.
    """
    provider = settings.llm_provider
    if provider in _API_KEY_PROVIDERS and not settings.openai_api_key:
        return None

    from langchain.chat_models import init_chat_model

    kwargs = {
        "temperature": 0,
        "timeout": settings.wall_clock_seconds,
        **_provider_kwargs(settings, provider),
        **overrides,
    }
    try:
        return init_chat_model(
            model_name_for(settings, purpose), model_provider=provider, **kwargs
        )
    except ImportError as exc:  # a provider whose package is not installed
        raise ValueError(
            f"LLM_PROVIDER={provider!r} needs an extra package: {exc}"
        ) from exc
    except ValueError as exc:  # init_chat_model's own "unsupported provider"
        raise ValueError(f"unsupported LLM_PROVIDER: {provider!r} ({exc})") from exc


def get_narration_model(settings: Settings):
    """For the event agent: one short call that rewrites computed facts as prose."""
    return get_model(settings, NARRATION, max_tokens=400)


def get_activity_model(settings: Settings):
    """For the activity agent: tool calling plus structured output."""
    return get_model(settings, ACTIVITY)
