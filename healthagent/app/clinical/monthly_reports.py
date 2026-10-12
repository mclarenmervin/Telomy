"""Deterministic monthly report composition with an explicit evidence cutoff."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from typing import Any


@dataclass(frozen=True)
class MonthlyReportDraft:
    body: str
    evidence: tuple[dict[str, Any], ...]
    source_cutoff: datetime


def _parse(value: Any) -> datetime | None:
    if isinstance(value, datetime):
        return value
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def _number(value: Any) -> str:
    if isinstance(value, float):
        return format(Decimal(str(value)).normalize(), "f")
    return str(value)


def compose_monthly_report(
    period_label: str,
    facts: list[dict[str, Any]],
    source_cutoff: datetime,
) -> MonthlyReportDraft:
    eligible = tuple(
        dict(fact)
        for fact in facts
        if (observed := _parse(fact.get("observed_at"))) is not None
        and observed <= source_cutoff
    )
    if not eligible:
        body = f"No eligible clinical measurements were available for {period_label}."
    else:
        lines = [f"Monthly clinical summary — {period_label}"]
        lines.extend(
            f"{item['label']}: {_number(item['value'])} {item.get('unit', '')}".rstrip()
            for item in eligible
        )
        body = "\n".join(lines)
    return MonthlyReportDraft(body=body, evidence=eligible, source_cutoff=source_cutoff)
