"""A confirmed panel puts findings in front of a clinician.

The producer and the spine both existed before this and nothing connected them,
which is the trap the handoff names about F4: a thing that is computed, stored
and consumed by nobody is not finished. Confirmation is the only real trigger —
a trend changes when a new result arrives, and the passage of time can only
ever remove a trend from eligibility (the history cutoff), never create one.

Queued rather than run inline, for the same reason the score recompute is: a
user uploading five years of reports in one sitting must not produce five years
of drafts synchronously inside an HTTP request.
"""

from datetime import date, timedelta

import pytest

from app.clinical.drafts import DRAFT_JOB_KIND
from app.score_worker.handlers import process_job
from tests.fakes import FakeSupabase

TODAY = date(2026, 10, 10)
USER = "11111111-0000-4000-8000-000000000001"
CLINIC = "33333333-0000-4000-8000-000000000003"


def result(value, days_ago, marker="hba1c", unit="%"):
    return {
        "user_id": USER,
        "biomarker_id": marker,
        "context": "standard",
        "result_type": "quantitative",
        "operator": "=",
        "value_canonical": value,
        "unit_canonical": unit,
        "collected_at": (TODAY - timedelta(days=days_ago)).isoformat(),
        "lab_name": "Test Labs",
        "status": "confirmed",
    }


def rising():
    return [result(5.4, 240), result(5.7, 120), result(6.0, 10)]


def job(**overrides):
    base = {"kind": DRAFT_JOB_KIND, "user_id": USER, "as_of": TODAY.isoformat()}
    base.update(overrides)
    return base


def db_with(results=(), members=(), drafts=()):
    return FakeSupabase({
        "biomarker_results": list(results),
        "clinic_members": list(members),
        "clinical_drafts": list(drafts),
    })


def test_a_confirmed_trend_becomes_a_draft():
    db = db_with(rising())

    process_job(job(), db)

    drafts = db.tables["clinical_drafts"]
    assert len(drafts) == 1
    assert drafts[0]["user_id"] == USER
    assert drafts[0]["status"] == "drafted"
    assert "HbA1c" in drafts[0]["title"]


def test_no_trend_produces_no_draft():
    db = db_with([result(5.4, 240), result(5.5, 10)])

    process_job(job(), db)

    assert db.tables["clinical_drafts"] == []


def test_the_users_clinic_is_the_reviewing_clinic():
    db = db_with(rising(), [{"clinic_id": CLINIC, "user_id": USER,
                             "role": "patient", "left_at": None}])

    process_job(job(), db)

    assert db.tables["clinical_drafts"][0]["clinic_id"] == CLINIC


def test_a_user_with_no_clinic_goes_to_the_network_pool():
    """Null clinic_id is the Bonphul pool, which any clinician in good standing
    may claim. A user not enrolled with a clinic still gets reviewed — refusing
    to draft for them would make the feature depend on an enrolment they may
    never have."""
    db = db_with(rising())

    process_job(job(), db)

    assert db.tables["clinical_drafts"][0]["clinic_id"] is None


def test_a_clinic_the_user_has_left_is_not_the_reviewing_clinic():
    db = db_with(rising(), [{"clinic_id": CLINIC, "user_id": USER,
                             "role": "patient", "left_at": "2026-01-01"}])

    process_job(job(), db)

    assert db.tables["clinical_drafts"][0]["clinic_id"] is None


def test_being_a_clinician_somewhere_does_not_route_your_own_findings_there():
    """A clinician who is also a user of the product. Their own lab findings
    belong to whichever clinic treats *them*, and routing them to the clinic
    they work for would put their panel in a queue their colleagues read."""
    db = db_with(rising(), [{"clinic_id": CLINIC, "user_id": USER,
                             "role": "clinician", "left_at": None}])

    process_job(job(), db)

    assert db.tables["clinical_drafts"][0]["clinic_id"] is None


def test_running_twice_does_not_draft_twice():
    """The webhook retries and a user may confirm several uploads in a row."""
    db = db_with(rising())

    process_job(job(), db)
    process_job(job(), db)

    assert len(db.tables["clinical_drafts"]) == 1


def test_a_score_job_is_not_treated_as_a_draft_job():
    from app.scheduler.plan import SCORE_RECOMPUTE

    db = db_with(rising())

    process_job(job(kind=SCORE_RECOMPUTE, score_kind="readiness"), db)

    assert db.tables["clinical_drafts"] == []


def test_an_unknown_job_kind_is_ignored_rather_than_guessed_at():
    db = db_with(rising())

    process_job(job(kind="something_else"), db)

    assert db.tables["clinical_drafts"] == []


def test_a_malformed_job_does_not_raise():
    """A poisoned job must not take the worker down."""
    db = db_with(rising())

    process_job({"kind": DRAFT_JOB_KIND}, db)
    process_job({"kind": DRAFT_JOB_KIND, "user_id": USER, "as_of": "not a date"}, db)

    assert db.tables["clinical_drafts"] == []


def test_a_database_failure_does_not_raise():
    class Broken(FakeSupabase):
        def table(self, name):
            raise RuntimeError("postgres is having a moment")

    process_job(job(), Broken())
