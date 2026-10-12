"""Deterministic doctor-workspace ordering; no model calls or inferred facts."""

from dataclasses import dataclass


@dataclass(frozen=True)
class PatientSignals:
    critical_escalation: bool = False
    overdue_reports: int = 0
    pending_drafts: int = 0
    stale_hours: int = 0
    missing_data: bool = False


@dataclass(frozen=True)
class Priority:
    score: int
    reasons: tuple[str, ...]
    critical: bool = False


def priority_for(signals: PatientSignals) -> Priority:
    if signals.critical_escalation:
        return Priority(score=1000, reasons=("Critical escalation",), critical=True)
    score = 0
    reasons: list[str] = []
    if signals.overdue_reports > 0:
        score += signals.overdue_reports * 20
        label = "report" if signals.overdue_reports == 1 else "reports"
        reasons.append(f"{signals.overdue_reports} overdue {label}")
    if signals.pending_drafts > 0:
        score += signals.pending_drafts * 5
        label = "draft" if signals.pending_drafts == 1 else "drafts"
        reasons.append(f"{signals.pending_drafts} {label} awaiting review")
    if signals.stale_hours >= 24:
        score += 10
        reasons.append(f"Data is {signals.stale_hours} hours old")
    if signals.missing_data:
        score += 5
        reasons.append("Recent data unavailable")
    return Priority(score=score, reasons=tuple(reasons))
