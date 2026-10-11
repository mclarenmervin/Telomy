"""The report envelope. The model supplies prose; every number here is ours."""


from pydantic import BaseModel, Field

# The figure check is shared with the concierge from F7: a fabricated number is
# a fabricated number whichever surface it appears on. `collect_tool_numbers` is
# re-exported because the graph imports it from here.
from app.agent.numbers import _NUMBER, check_numbers, collect_tool_numbers
from app.analytics.severity import ATTENTION, NORMAL, URGENT, annotate
from app.common.thresholds import get_thresholds

SCHEMA_VERSION = 2
SECTION_IDS = ("what_happened", "what_changed", "what_went_well", "watch_outs", "improve")
SECTION_TITLES = {
    "what_happened": "What happened",
    "what_changed": "What changed",
    "what_went_well": "What went well",
    "watch_outs": "Worth watching",
    "improve": "What to try next time",
}
class NarrativeSection(BaseModel):
    id: str = Field(description="One of: " + ", ".join(SECTION_IDS))
    title: str
    body: str


class Narrative(BaseModel):
    """Prose only — the model never returns metrics, scores, or data quality."""

    headline: str = Field(description="One sentence for a list view.")
    sections: list[NarrativeSection]


# Written here, not by the model, so the call to action cannot be softened by a
# generation. No phone number: it could not be changed without a redeploy, could not
# vary by region, and would be wrong for most users.
ESCALATION_LEVELS = {NORMAL: "routine", ATTENTION: "recommended", URGENT: "urgent"}
ESCALATION_COPY = {
    "routine": (
        "Book a consultation",
        "Nothing here needs attention, but you can talk this through with a "
        "practitioner whenever you want to.",
    ),
    "recommended": (
        "Worth getting checked",
        "One of your readings moved outside your usual range. It is worth having "
        "someone look at it properly.",
    ),
    "urgent": (
        "Please get this checked",
        "A reading from this session is outside a safe range. Please arrange to see "
        "a practitioner. If you feel unwell, have chest pain, or trouble breathing, "
        "seek medical care right away.",
    ),
}


def build_escalation(severity: str) -> dict:
    level = ESCALATION_LEVELS.get(severity, "routine")
    title, body = ESCALATION_COPY[level]
    return {"level": level, "title": title, "body": body, "action": "book_consultation"}


def build_report(analysis, insights, narrative, data_gaps, profile=None) -> dict:
    by_id = {s.id: s for s in narrative.sections}
    sections = [
        {
            "id": sid,
            "title": SECTION_TITLES[sid],
            "body": (by_id[sid].body if sid in by_id else "").strip(),
        }
        for sid in SECTION_IDS
    ]
    metrics, severity = annotate(
        analysis.get("metrics") or [], profile or {}, get_thresholds()
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "score_version": (analysis.get("score") or {}).get("score_version", 1),
        "event_type": analysis.get("activity_type"),
        "score": analysis.get("score"),
        "headline": narrative.headline.strip(),
        "sections": sections,
        "metrics": metrics,
        "severity": severity,
        "escalation": build_escalation(severity),
        "data_quality": analysis.get("data_quality", "none"),
        "history_used": analysis.get("history_used") or {},
        "data_gaps": data_gaps or [],
        "insights": insights or [],
    }


def _allowed_numbers(analysis) -> set[str]:
    allowed: set[str] = set()

    def add(value):
        """Admit every form a careful writer might use for one computed value.

        A mean of 148.6 may fairly be written 148, 148.0, 148.6 or 149; rejecting those
        would make the flag fire on correct prose and destroy its signal.
        """
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            magnitude = abs(value)
            for form in (int(magnitude), round(magnitude), magnitude):
                allowed.add(f"{form:.0f}")  # 148
                allowed.add(f"{form:.1f}")  # 148.0
                allowed.add(f"{form:.1f}".rstrip("0").rstrip("."))  # 148.6 / 148

    for metric in analysis.get("metrics") or []:
        for key in ("value", "min", "max", "baseline", "delta", "samples"):
            add(metric.get(key))
    for value in (analysis.get("baseline") or {}).values():
        add(value)
    add((analysis.get("score") or {}).get("value"))
    seconds = analysis.get("duration_seconds") or 0
    add(seconds)
    # Both roundings: the prompt presents round(s/60), so allowing only the floor would
    # flag a correct restatement on any duration with a remainder of 30s or more.
    add(seconds // 60)
    add(round(seconds / 60) if seconds else 0)
    add((analysis.get("history_used") or {}).get("sessions_compared"))
    return allowed


def verify_numbers(report_dict, analysis, extra_allowed=None) -> tuple[dict, list[str]]:
    """Cheap deterministic fidelity check: prose figures must trace to computed values."""
    flags: list[str] = []
    allowed = _allowed_numbers(analysis) | set(extra_allowed or ())
    texts = [report_dict["headline"]] + [s["body"] for s in report_dict["sections"]]

    unverified = {n for text in texts for n in check_numbers(text, allowed).unverified}

    if analysis.get("data_quality") == "none" and unverified:
        # Strip only figures that do not trace to computed values; the duration does,
        # so the ring-dropped report stays readable instead of becoming "—-minute".
        def strip(text: str) -> str:
            return _NUMBER.sub(lambda m: "—" if m.group() in unverified else m.group(), text)

        for section in report_dict["sections"]:
            section["body"] = strip(section["body"])
        report_dict["headline"] = strip(report_dict["headline"])
        flags.append("quality_gate")
    elif unverified:
        flags.append("unverified_number")

    return report_dict, flags


def fallback_narrative(analysis, insights, profile=None) -> Narrative:
    """Used when no model is available or a budget cap was hit — deterministic prose.

    It is also the remedy the graph substitutes for a narrative that failed to
    acknowledge a raised severity, so it must itself acknowledge one. Its watch-outs
    therefore come from the annotated metrics, not from `insight_rules`: those rules
    fire on only two conditions, while severity is raised by six, and the gap used to
    publish "Nothing flagged." beside an amber "Worth getting checked" card.
    """
    minutes = round((analysis.get("duration_seconds") or 0) / 60)
    activity = analysis.get("activity_type") or "activity"
    metric_bits = (
        ", ".join(
            f"{m['key']} averaged {m['value']}" for m in (analysis.get("metrics") or [])[:3]
        )
        or "no sensor metrics were captured"
    )
    by_section: dict[str, list[str]] = {sid: [] for sid in SECTION_IDS}
    for insight in insights or []:
        by_section.setdefault(insight["section"], []).append(insight["fact"])

    annotated, _ = annotate(analysis.get("metrics") or [], profile or {}, get_thresholds())
    flagged = [m["note"] for m in annotated if m["severity"] != NORMAL and m.get("note")]

    bodies = {
        "what_happened": f"You recorded a {minutes}-minute {activity} session.",
        "what_changed": metric_bits[0].upper() + metric_bits[1:] + ".",
        "what_went_well": " ".join(by_section["what_went_well"]) or "Session recorded.",
        "watch_outs": " ".join(by_section["watch_outs"] + flagged) or "Nothing flagged.",
        "improve": " ".join(by_section["improve"])
        or "Keep logging sessions to build a clearer picture.",
    }
    return Narrative(
        headline=f"{minutes}-minute {activity} session recorded.",
        sections=[
            NarrativeSection(id=s, title=SECTION_TITLES[s], body=bodies[s]) for s in SECTION_IDS
        ],
    )
