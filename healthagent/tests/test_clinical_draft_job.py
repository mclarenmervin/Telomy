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


# ── Supplements ──────────────────────────────────────────────────────────────
#
# The same job, because the trigger is the same: a confirmed panel. A separate
# job would mean two queue entries per confirmation, two sweeps to reason about
# and two chances for one of them to be the one that never ran.
#
# What the supplement half needs that the trend half does not is the rest of the
# person: their date of birth and sex decide whether anything may be recommended
# to them at all, and their medications decide what the draft has to say.

from app.analytics import catalog, supplement_rules  # noqa: E402


@pytest.fixture
def signed(monkeypatch, tmp_path):
    """The rule file and the catalog signed off, as a clinician would.

    Without this the job produces no supplement drafts at all, which is the
    shipped state and the first thing asserted below.
    """
    import yaml

    def clear():
        for cache in (catalog.load_catalog, catalog.review_status,
                      catalog.alias_index, supplement_rules.load_rules,
                      supplement_rules.review_status, supplement_rules.rules_for):
            cache.cache_clear()

    raw = yaml.safe_load(supplement_rules.RULES_PATH.read_text())
    path = tmp_path / "supplements.yaml"
    path.write_text(yaml.safe_dump(raw, sort_keys=False))
    monkeypatch.setattr(supplement_rules, "RULES_PATH", path)
    clear()
    raw["clinical_review"]["rules"] = [
        {"id": "vitamin_d_repletion",
         "reviewer": "Dr A. Example, MBBS MD, reg. 12345",
         "reviewed_at": "2026-10-10",
         "content_sha256": supplement_rules.rule_fingerprint("vitamin_d_repletion")}
    ]
    path.write_text(yaml.safe_dump(raw, sort_keys=False))
    clear()

    craw = yaml.safe_load(catalog.CATALOG_PATH.read_text())
    cpath = tmp_path / "biomarkers.yaml"
    cpath.write_text(yaml.safe_dump(craw, sort_keys=False))
    monkeypatch.setattr(catalog, "CATALOG_PATH", cpath)
    clear()
    craw["clinical_review"]["markers"] = [
        {"id": "vitamin_d_25oh", "reviewer": "Dr A. Example, MBBS MD, reg. 12345",
         "reviewed_at": "2026-10-10",
         "content_sha256": catalog.marker_fingerprint("vitamin_d_25oh")}
    ]
    cpath.write_text(yaml.safe_dump(craw, sort_keys=False))
    clear()
    yield
    clear()


LOW_D = [result(14, 10, marker="vitamin_d_25oh", unit="ng/mL")]
ADULT = [{"user_id": USER, "profile": {"dob": "1985-03-02", "sex": "female"}}]


def db_for_supplements(results=LOW_D, profile=ADULT, medications=()):
    return FakeSupabase({
        "biomarker_results": list(results),
        "clinic_members": [],
        "clinical_drafts": [],
        "user_preferences": list(profile),
        "medications": list(medications),
    })


def test_a_deficiency_becomes_a_supplement_draft(signed):
    db = db_for_supplements()

    process_job(job(), db)

    drafts = db.tables["clinical_drafts"]
    assert len(drafts) == 1
    assert drafts[0]["kind"] == "supplement"
    assert drafts[0]["routing_flags"] == ["medication"]


def test_no_supplement_draft_while_the_rules_are_unsigned():
    """The shipped state: the job runs, finds the deficiency, and writes
    nothing, because no clinician has agreed what to do about one."""
    db = db_for_supplements()

    process_job(job(), db)

    assert db.tables["clinical_drafts"] == []


def test_the_draft_names_the_medication_that_complicates_it(signed):
    """The job has to actually fetch the medications. A supplement draft built
    without them is the confidently wrong version of this feature."""
    db = db_for_supplements(
        medications=[{"user_id": USER, "title": "Hydrochlorothiazide 12.5mg",
                      "notes": "morning", "recorded_at": "2026-09-01"}],
    )

    process_job(job(), db)

    assert "Hydrochlorothiazide" in db.tables["clinical_drafts"][0]["body"]


def test_a_profile_the_rule_refuses_produces_no_supplement_draft(signed):
    """The job has to pass the subject through, not substitute a default one.
    A missing date of birth means the minimum age cannot be enforced."""
    db = db_for_supplements(profile=[{"user_id": USER, "profile": {"sex": "female"}}])

    process_job(job(), db)

    assert db.tables["clinical_drafts"] == []


def test_a_trend_and_a_deficiency_are_both_drafted(signed):
    """One confirmation, two kinds of finding, one job. The trend draft stays
    unflagged and the supplement draft does not, which is the asymmetry and the
    reason both must come out of the same pass."""
    db = db_for_supplements(results=rising() + LOW_D)

    process_job(job(), db)

    by_kind = {d["kind"]: d for d in db.tables["clinical_drafts"]}
    assert set(by_kind) == {"lab_finding", "supplement"}
    assert by_kind["lab_finding"]["routing_flags"] == []
    assert by_kind["supplement"]["routing_flags"] == ["medication"]


def test_running_twice_does_not_draft_a_supplement_twice(signed):
    db = db_for_supplements()

    process_job(job(), db)
    process_job(job(), db)

    assert len(db.tables["clinical_drafts"]) == 1


def test_a_supplement_failure_does_not_lose_the_trend_draft(signed, monkeypatch):
    """Two producers in one job, and one of them raising must not silently take
    the other's findings with it."""
    import app.score_worker.handlers as handlers

    def boom(*args, **kwargs):
        raise RuntimeError("the rule file is on fire")

    monkeypatch.setattr(handlers, "supplement_drafts", boom)
    db = db_for_supplements(results=rising() + LOW_D)

    process_job(job(), db)

    kinds = [d["kind"] for d in db.tables["clinical_drafts"]]
    assert kinds == ["lab_finding"]
