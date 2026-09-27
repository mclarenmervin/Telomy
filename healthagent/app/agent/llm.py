from typing import Protocol

from app.common.config import Settings


class LLM(Protocol):
    def complete(self, system: str, user: str) -> str: ...


class OpenAILLM:
    def __init__(self, api_key: str, model: str):
        from openai import OpenAI

        self._client = OpenAI(api_key=api_key)
        self._model = model

    def complete(self, system: str, user: str) -> str:
        response = self._client.chat.completions.create(
            model=self._model,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            max_completion_tokens=400,
        )
        return response.choices[0].message.content or ""


def build_llm(settings: Settings) -> LLM | None:
    if settings.llm_provider != "openai":
        raise ValueError(f"unsupported LLM_PROVIDER: {settings.llm_provider}")
    if not settings.openai_api_key:
        return None
    return OpenAILLM(settings.openai_api_key, settings.llm_model)
