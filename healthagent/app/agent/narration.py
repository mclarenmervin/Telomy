from app.common.logging_config import get_logger

logger = get_logger(__name__)

LABELS = {
    "heartRate": ("heart rate", "bpm"),
    "hrv": ("HRV", "ms"),
    "temperature": ("skin temperature", "°C"),
    "spo2": ("SpO2", "%"),
}

SYSTEM_PROMPT = (
    "You are a wellness assistant. In 2-3 short sentences, explain how the user's "
    "readings changed during the event compared with their own usual level. Use ONLY "
    "the numbers provided. These are correlations, not causes. Never diagnose, and "
    "never give medication or dosage advice."
)


def _fmt(value: float) -> str:
    return f"{round(value, 1):g}"


def _metric_lines(analysis: dict) -> list[str]:
    lines = []
    for key, (label, unit) in LABELS.items():
        metric = analysis.get("metrics", {}).get(key) or {}
        during = metric.get("during_mean")
        if during is None:
            continue
        line = f"{label} averaged {_fmt(during)} {unit}"
        delta, base = metric.get("delta_during"), metric.get("baseline_mean")
        if delta is not None and base is not None:
            direction = "above" if delta >= 0 else "below"
            line += f" ({_fmt(abs(delta))} {direction} your usual {_fmt(base)})"
        lines.append(line)
    return lines


def _missing_text(event_type: str) -> str:
    return (
        f"I don't have enough readings around your {event_type} session yet. "
        "I'll update this when your ring syncs."
    )


def fallback_summary(event_type: str, analysis: dict) -> str:
    lines = _metric_lines(analysis)
    if analysis.get("data_quality") == "none" or not lines:
        return _missing_text(event_type)
    return f"During your {event_type} session, " + "; ".join(lines) + "."


def build_prompt(event_type: str, analysis: dict) -> tuple[str, str]:
    lines = _metric_lines(analysis)
    user = (
        f"Event: {event_type}\n"
        f"Data quality: {analysis.get('data_quality')}\n"
        "Computed readings:\n" + "\n".join(f"- {line}" for line in lines)
    )
    return SYSTEM_PROMPT, user


def narrate(llm, event_type: str, analysis: dict) -> str:
    if llm is None or analysis.get("data_quality") == "none":
        return fallback_summary(event_type, analysis)
    system, user = build_prompt(event_type, analysis)
    try:
        # A LangChain chat model, same as the activity agent uses — see app/common/llm.py.
        text = str(llm.invoke([("system", system), ("human", user)]).content).strip()
    except Exception:
        logger.exception("llm call failed, using fallback summary")
        return fallback_summary(event_type, analysis)
    return text or fallback_summary(event_type, analysis)
