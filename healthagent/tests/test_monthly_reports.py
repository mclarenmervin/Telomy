from datetime import UTC, datetime

from app.clinical.monthly_reports import compose_monthly_report


def test_report_uses_only_evidence_at_or_before_cutoff_and_is_stable():
    cutoff = datetime(2026, 10, 1, tzinfo=UTC)
    facts = [
        {"label": "Resting heart rate", "value": 68, "unit": "bpm", "observed_at": "2026-09-30T08:00:00Z", "source": "ring_daily"},
        {"label": "Future value", "value": 999, "unit": "bpm", "observed_at": "2026-10-02T08:00:00Z", "source": "ring_daily"},
    ]
    report = compose_monthly_report("September 2026", facts, cutoff)
    assert report == compose_monthly_report("September 2026", facts, cutoff)
    assert "68 bpm" in report.body
    assert "999" not in report.body
    assert len(report.evidence) == 1


def test_report_states_when_no_evidence_exists():
    report = compose_monthly_report("September 2026", [], datetime(2026, 10, 1, tzinfo=UTC))
    assert report.body == "No eligible clinical measurements were available for September 2026."
