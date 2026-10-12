from app.clinical.summaries import compose_patient_summary


def test_summary_is_stable_and_every_number_has_provenance():
    facts = {
        "patient_name": "Patient A",
        "period": "Last 7 days",
        "metrics": [
            {"label": "Resting heart rate", "value": 68, "unit": "bpm", "source": "ring_daily", "observed_at": "2026-10-12T08:00:00Z"},
            {"label": "Sleep", "value": 7.2, "unit": "hours", "source": "ring_sleep", "observed_at": "2026-10-12T07:00:00Z"},
        ],
    }
    summary = compose_patient_summary(facts)
    assert summary == compose_patient_summary(facts)
    assert "68 bpm" in summary.text and "7.2 hours" in summary.text
    assert {item.source for item in summary.evidence} == {"ring_daily", "ring_sleep"}


def test_missing_data_sentence_is_explicit():
    summary = compose_patient_summary({"patient_name": "Patient A", "period": "Last 7 days", "metrics": []})
    assert summary.text == "No recent clinical measurements are available for Last 7 days."
    assert summary.evidence == ()
