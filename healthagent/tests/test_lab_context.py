"""What the agent may know about a lab report.

Retrieval, not interpretation. The agent can state that an HbA1c was 7.8% on a
date, and compare it with the one before. It is not given a verdict, because
`biomarkers.v1.yaml` has not been reviewed by a clinician and the app itself
shows these values with no grading for exactly that reason. An agent that read
the same number and called it "high" would walk straight around that gate.

The hard rule is the status filter. An `extracted` row has not been checked by
anyone, and a value the user has never seen must never come back out of the
model's mouth as fact.
"""

from app.common.context_loader import ContextLoader
from tests.fakes import FakeSupabase

USER, OTHER = "user-1", "user-2"


def result(**overrides):
    row = {
        "user_id": USER, "biomarker_id": "hba1c", "context": "standard",
        "result_type": "quantitative", "operator": "=", "raw_value": "7.8",
        "raw_unit": "%", "value_canonical": 7.8, "unit_canonical": "%",
        "value_text": None, "status": "confirmed",
        "collected_at": "2026-09-28T07:30:00+00:00", "lab_name": "Dr Lal PathLabs",
    }
    row.update(overrides)
    return row


def test_confirmed_values_are_available():
    loader = ContextLoader(FakeSupabase({"biomarker_results": [result()]}))

    out = loader.biomarker_results(USER)

    assert out["status"] == "ok"
    assert out["items"][0]["biomarker_id"] == "hba1c"
    assert out["items"][0]["value_canonical"] == 7.8


def test_an_unconfirmed_value_is_never_exposed():
    """The gate the whole confirmation step exists to enforce. A value the user
    has not checked must not reach the agent, which would state it as fact."""
    loader = ContextLoader(FakeSupabase({"biomarker_results": [result(status="extracted")]}))

    assert loader.biomarker_results(USER)["status"] == "empty"


def test_a_rejected_value_is_never_exposed():
    loader = ContextLoader(FakeSupabase({"biomarker_results": [result(status="rejected")]}))

    assert loader.biomarker_results(USER)["status"] == "empty"


def test_a_corrected_value_is_exposed():
    """The user fixed it, so it is checked -- more trustworthy than extracted,
    not less."""
    loader = ContextLoader(
        FakeSupabase({"biomarker_results": [result(status="corrected", raw_value="6.5")]})
    )

    assert loader.biomarker_results(USER)["items"][0]["raw_value"] == "6.5"


def test_results_are_scoped_to_the_user():
    """The worker and agent hold service-role credentials and bypass RLS, so
    this filter is the only thing between one person's labs and another's."""
    rows = [result(), result(user_id=OTHER, biomarker_id="ferritin")]
    loader = ContextLoader(FakeSupabase({"biomarker_results": rows}))

    assert [i["biomarker_id"] for i in loader.biomarker_results(USER)["items"]] == ["hba1c"]


def test_a_single_marker_can_be_asked_for():
    """"How has my HbA1c moved?" should not require reading the whole panel."""
    rows = [result(), result(biomarker_id="ferritin", raw_value="60")]
    loader = ContextLoader(FakeSupabase({"biomarker_results": rows}))

    out = loader.biomarker_results(USER, biomarker_id="hba1c")

    assert [i["biomarker_id"] for i in out["items"]] == ["hba1c"]


def test_no_results_is_empty_not_unconfigured():
    """"We looked and found none" is a different statement from "we could not
    look", and the agent is told to keep them apart."""
    loader = ContextLoader(FakeSupabase({"biomarker_results": []}))

    assert loader.biomarker_results(USER)["status"] == "empty"


def test_no_verdict_is_included():
    """Deliberately absent. The ranges are unreviewed, the app shows these
    values with no grading, and handing the model a grade would make it the
    thing that interprets them."""
    loader = ContextLoader(FakeSupabase({"biomarker_results": [result()]}))

    item = loader.biomarker_results(USER)["items"][0]

    for forbidden in ("grade", "status_label", "interpretation", "is_normal"):
        assert forbidden not in item


def test_a_censored_value_keeps_its_operator():
    """`<3.0` must not read as 3.0 in a sentence the agent writes."""
    loader = ContextLoader(
        FakeSupabase({"biomarker_results": [
            result(biomarker_id="vitamin_d_25oh", operator="<", raw_value="3.0")
        ]})
    )

    assert loader.biomarker_results(USER)["items"][0]["operator"] == "<"
