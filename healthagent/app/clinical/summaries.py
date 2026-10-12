"""Pure, deterministic clinical summary composition from supplied facts."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Any


@dataclass(frozen=True)
class Evidence:
    label: str
    value: int | float | str
    unit: str
    source: str
    observed_at: str


@dataclass(frozen=True)
class ComposedSummary:
    text: str
    evidence: tuple[Evidence, ...]


def _display(value: Any) -> str:
    if isinstance(value, float):
        return format(Decimal(str(value)).normalize(), "f")
    return str(value)


def compose_patient_summary(facts: dict[str, Any]) -> ComposedSummary:
    period = str(facts.get("period") or "the selected period")
    metrics = facts.get("metrics") or []
    evidence = tuple(
        Evidence(
            label=str(item["label"]),
            value=item["value"],
            unit=str(item.get("unit") or ""),
            source=str(item["source"]),
            observed_at=str(item["observed_at"]),
        )
        for item in metrics
    )
    if not evidence:
        return ComposedSummary(
            text=f"No recent clinical measurements are available for {period}.",
            evidence=(),
        )
    sentences = [
        f"{item.label}: {_display(item.value)} {item.unit}".rstrip() + "."
        for item in evidence
    ]
    return ComposedSummary(text=" ".join(sentences), evidence=evidence)
