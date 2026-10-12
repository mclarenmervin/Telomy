from app.clinical.doctor_priority import PatientSignals, priority_for


def test_critical_escalation_is_always_highest_and_named_separately():
    critical = priority_for(PatientSignals(critical_escalation=True))
    busy = priority_for(PatientSignals(overdue_reports=3, pending_drafts=8))
    assert critical.score > busy.score
    assert critical.critical is True
    assert critical.reasons == ("Critical escalation",)


def test_priority_is_deterministic_and_reasons_trace_inputs():
    signals = PatientSignals(overdue_reports=1, pending_drafts=2, stale_hours=30)
    first = priority_for(signals)
    assert first == priority_for(signals)
    assert first.score == 40
    assert first.reasons == ("1 overdue report", "2 drafts awaiting review", "Data is 30 hours old")


def test_missing_data_is_visible_not_invented():
    result = priority_for(PatientSignals(missing_data=True))
    assert result.score == 5
    assert result.reasons == ("Recent data unavailable",)
