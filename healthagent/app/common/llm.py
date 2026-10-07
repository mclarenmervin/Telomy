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

Per-purpose overrides: `LLM_<SETTING>_<PURPOSE>` overrides one caller's provider,
model, api_key or base_url. This is not only about cost. Groq cannot serve the
activity agent at all — it rejects tool calling and a response schema in the same
request ("json mode cannot be combined with tool/function calling") — but it
handles narration, which is a single call with neither. So:

    LLM_PROVIDER=openai           LLM_MODEL=gpt-5.4-mini
    LLM_PROVIDER_NARRATION=groq   LLM_MODEL_NARRATION=openai/gpt-oss-120b
    LLM_API_KEY_NARRATION=gsk_...

runs narration on Groq and leaves the activity agent on OpenAI.
`scripts/check_llm_provider.py` tells you which side of that line a provider
falls on.
"""

from app.common.config import Settings

# Providers that authenticate with an API key. Bedrock is deliberately absent:
# it uses AWS SigV4 (an IAM role or the standard AWS_* credentials), so there is
# no key to check and an unset OPENAI_API_KEY must not disable it.
_API_KEY_PROVIDERS = frozenset({"openai", "groq", "anthropic", "together", "deepseek", "xai"})

NARRATION = "narration"
ACTIVITY = "activity"
# Lab extraction's one model call: which biomarker does this printed label name?
# Its own purpose so it can run on a cheap provider -- it is a short
# classification with no tools and no response schema, which Groq handles well.
LABEL_MAPPING = "label_mapping"


def config_for(settings: Settings, purpose: str | None = None) -> dict:
    """Resolve provider/model/key/base_url for one purpose, over the defaults."""
    resolved = {
        "provider": settings.llm_provider,
        "model": settings.llm_model,
        "api_key": settings.openai_api_key,
        "base_url": settings.llm_base_url,
    }
    if purpose:
        overrides = settings.llm_overrides.get(purpose, {})
        resolved.update({k: v for k, v in overrides.items() if v})
        # A purpose that switches provider without naming its own key would
        # otherwise silently send the default provider's key to a new vendor.
        if "provider" in overrides and "api_key" not in overrides:
            resolved["api_key"] = settings.openai_api_key
    return resolved


def model_name_for(settings: Settings, purpose: str | None = None) -> str:
    """The model this purpose should use, falling back to the default."""
    return config_for(settings, purpose)["model"]


def _provider_kwargs(cfg: dict) -> dict:
    """Provider-specific arguments.

    These genuinely differ — Bedrock takes a region and no key at all — so the
    shape cannot be one fixed signature without breaking when Bedrock is added.
    """
    provider = cfg["provider"]
    if provider.startswith("bedrock"):
        return {"region_name": cfg.get("aws_region")} if cfg.get("aws_region") else {}
    kwargs: dict = {"api_key": cfg["api_key"]}
    # Only OpenAI-compatible endpoints take a base URL; passing it to others errors.
    if cfg["base_url"] and provider == "openai":
        kwargs["base_url"] = cfg["base_url"]
    return kwargs


def get_model(settings: Settings, purpose: str | None = None, **overrides):
    """Return a configured chat model, or None when no credentials are set.

    None is a supported state, not a failure: both agents fall back to
    deterministic prose, which is why a missing key degrades the wording rather
    than breaking the report.
    """
    cfg = config_for(settings, purpose)
    cfg["aws_region"] = settings.aws_region
    provider = cfg["provider"]
    if provider in _API_KEY_PROVIDERS and not cfg["api_key"]:
        return None

    from langchain.chat_models import init_chat_model

    kwargs = {
        "temperature": 0,
        "timeout": settings.wall_clock_seconds,
        **_provider_kwargs(cfg),
        **overrides,
    }
    try:
        return init_chat_model(cfg["model"], model_provider=provider, **kwargs)
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
