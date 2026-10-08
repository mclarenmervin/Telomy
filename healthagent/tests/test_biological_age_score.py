"""Biological age as a stored score.

Same seam readiness uses: one implementation in `app.analytics.scores`, called
by the REST endpoint, the score worker and the agent's tool, so a number on a
chart and a number in a sentence cannot disagree.

Two properties here are the plan's, not ours to choose:

**Reproducibility.** A stored snapshot must recompute from its own `inputs` and
`ranges_version` byte-identically. A range changed tomorrow produces a NEW
snapshot; it cannot retroactively rewrite a number someone has already read.

**Honesty about the date.** A biological age is a property of a blood draw, so
the snapshot is dated to the draw -- not to the day the sweep happened to run.
"""

from datetime import date, datetime

import pytest

from app.analytics import catalog
from app.analytics.biological_age import MODEL_VERSION
from app.analytics.score_snapshot import NONE
from app.analytics.scores import (
    BIOLOGICAL_AGE,
    biological_age_inputs,
    compute_biological_age,
    persist_snapshot,
    snapshot_from_inputs,
)
from tests.fakes import FakeSupabase

ALICE = "00000000-0000-0000-0000-00000000000a"
DRAWN = date(2026, 6, 15)
TODAY = date(2026, 10, 8)

CANONICAL = {
    "albumin": 4.2,
    "creatinine": 0.96,
    "glucose_fasting": 97.0,
    "hs_crp": 1.5,
    "lymphocyte_percent": 28.0,
    "mcv": 90.0,
    "rdw": 13.5,
    "alkaline_phosphatase": 75.0,
    "wbc": 6.8,
}

UNITS = {
    "albumin": "g/dL", "creatinine": "mg/dL", "glucose_fasting": "mg/dL",
    "hs_crp": "mg/L", "lymphocyte_percent": "%", "mcv": "fL", "rdw": "%",
    "alkaline_phosphatase": "U/L", "wbc": "10^3/uL",
}


@pytest.fixture
def reviewed(monkeypatch):
    monkeypatch.setattr(
        catalog, "review_status",
        lambda: catalog.ClinicalReview(True, "Dr A Reviewer", "2026-10-01"),
    )


def result(biomarker_id, value, collected_at=DRAWN, *, context=None, **overrides):
    row = {
        "user_id": ALICE,
        "biomarker_id": biomarker_id,
        "context": context or ("fasting" if biomarker_id == "glucose_fasting"
                               else "standard"),
        "result_type": "quantitative",
        "operator": "=",
        "raw_value": str(value),
        "raw_unit": UNITS[biomarker_id],
        "value_canonical": value,
        "unit_canonical": UNITS[biomarker_id],
        "value_text": None,
        "status": "confirmed",
        "collected_at": f"{collected_at}T07:30:00+00:00",
        "lab_name": "Dr Lal PathLabs",
    }
    row.update(overrides)
    return row


def panel_rows(collected_at=DRAWN, **overrides):
    values = dict(CANONICAL)
    values.update(overrides)
    return [result(m, v, collected_at) for m, v in values.items()]


def make_db(results=None, profile=None):
    return FakeSupabase({
        "biomarker_results": panel_rows() if results is None else results,
        "user_preferences": [{
            "user_id": ALICE,
            "profile": profile if profile is not None else {"dob": "1981-02-10"},
        }],
        "score_snapshots": [],
    })


# ── The snapshot ─────────────────────────────────────────────────────────────

def test_a_complete_panel_produces_a_biological_age_snapshot(reviewed):
    snapshot = compute_biological_age(make_db(), ALICE, TODAY)

    assert snapshot["score_kind"] == BIOLOGICAL_AGE
    assert snapshot["value"] == pytest.approx(43.2, abs=0.6)
    assert snapshot["data_quality"] == "full"
    assert snapshot["model_version"] == MODEL_VERSION


def test_the_snapshot_is_dated_to_the_blood_draw_not_to_the_sweep(reviewed):
    """A biological age is a property of a draw. Dating it to the day the
    scheduler happened to run would put a June panel on October's chart and
    would write a fresh identical row every night."""
    snapshot = compute_biological_age(make_db(), ALICE, TODAY)

    assert snapshot["as_of_date"] == DRAWN.isoformat()


def test_the_range_set_is_stamped_so_a_catalog_change_cannot_rewrite_history(
    reviewed,
):
    """The critical bounds that decide a refusal and the optimal midpoints the
    drivers are measured against both come from the catalog, so which catalog
    is part of what the number means."""
    snapshot = compute_biological_age(make_db(), ALICE, TODAY)

    assert snapshot["ranges_version"] == catalog.catalog_version()


def test_results_collected_after_the_requested_date_are_not_considered(reviewed):
    """`as_of` is an upper bound. Asking what someone's biological age was in
    June must not reach for a panel drawn in September."""
    rows = panel_rows(DRAWN) + panel_rows(date(2026, 9, 20))

    snapshot = compute_biological_age(make_db(rows), ALICE, date(2026, 7, 1))

    assert snapshot["as_of_date"] == DRAWN.isoformat()


def test_drivers_carry_each_marker_s_contribution_in_years(reviewed):
    snapshot = compute_biological_age(make_db(), ALICE, TODAY)

    names = {d["name"] for d in snapshot["drivers"]}
    assert "rdw" in names
    assert all("detail" in d for d in snapshot["drivers"])


# ── When we cannot produce one ───────────────────────────────────────────────

def test_an_incomplete_panel_stores_unknown_rather_than_a_number(reviewed):
    """Null is a real answer. A zero biological age is not, and the table's own
    constraint agrees."""
    rows = [r for r in panel_rows() if r["biomarker_id"] != "mcv"]

    snapshot = compute_biological_age(make_db(rows), ALICE, TODAY)

    assert snapshot["value"] is None
    assert snapshot["data_quality"] == NONE
    assert "mcv" in snapshot["missing_inputs"]


def test_a_rejected_row_explains_itself_in_the_snapshot(reviewed):
    """The app can then ask for a fasting glucose rather than claiming the user
    has no glucose result at all."""
    rows = [r for r in panel_rows() if r["biomarker_id"] != "glucose_fasting"]
    rows.append(result("glucose_fasting", 168.0, DRAWN, context="post_prandial"))

    snapshot = compute_biological_age(make_db(rows), ALICE, TODAY)

    assert "glucose_fasting:wrong_context" in snapshot["missing_inputs"]


def test_no_date_of_birth_refuses_and_says_so(reviewed):
    snapshot = compute_biological_age(make_db(profile={}), ALICE, TODAY)

    assert snapshot["value"] is None
    assert "date_of_birth" in snapshot["missing_inputs"]


def test_a_user_with_no_lab_results_at_all_gets_an_honest_empty_snapshot(reviewed):
    """Dated to the day we looked, because there is no draw to date it to."""
    snapshot = compute_biological_age(make_db([]), ALICE, TODAY)

    assert snapshot["value"] is None
    assert snapshot["as_of_date"] == TODAY.isoformat()
    assert snapshot["data_quality"] == NONE


def test_only_confirmed_results_are_used(reviewed):
    """An `extracted` row has been read by a machine and checked by nobody.
    Computing a biological age from one would make the confirmation step
    decorative."""
    rows = [dict(r, status="extracted") for r in panel_rows()]

    snapshot = compute_biological_age(make_db(rows), ALICE, TODAY)

    assert snapshot["value"] is None


def test_a_corrected_result_counts_as_confirmed(reviewed):
    """The user looked at the extracted value, said it was wrong, and typed the
    right one. That is the most trustworthy state a row can be in."""
    rows = [dict(r, status="corrected") for r in panel_rows()]

    assert compute_biological_age(make_db(rows), ALICE, TODAY)["value"] is not None


# ── Reproducibility ──────────────────────────────────────────────────────────

def test_a_snapshot_recomputes_from_its_own_inputs_byte_identically(reviewed):
    """The plan's requirement. The snapshot is a pure function of an inputs dict
    that describes itself completely -- the nine values, their collection dates
    and contexts, the subject, and both versions -- so a stored number stays
    explicable exactly as it was produced even after the rows behind it have
    been corrected.

    `computed_at` is passed in rather than taken from the clock, because it is
    metadata about the run and not an input to the number.
    """
    inputs = biological_age_inputs(make_db(), ALICE, TODAY)
    at = datetime(2026, 10, 8, 3, 0, 0)

    first = snapshot_from_inputs(ALICE, inputs, computed_at=at)
    second = snapshot_from_inputs(ALICE, inputs, computed_at=at)

    assert first == second


def test_recomputation_does_not_need_the_database_the_rows_came_from(reviewed):
    """If it did, a corrected result would silently change what an old snapshot
    claims -- which is the retroactive rewrite the whole envelope exists to
    prevent."""
    inputs = biological_age_inputs(make_db(), ALICE, TODAY)
    expected = compute_biological_age(make_db(), ALICE, TODAY)

    recomputed = snapshot_from_inputs(ALICE, inputs)

    assert recomputed["value"] == expected["value"]
    assert recomputed["inputs_hash"] == expected["inputs_hash"]
    assert recomputed["drivers"] == expected["drivers"]
    assert recomputed["as_of_date"] == expected["as_of_date"]


def test_the_fingerprint_does_not_change_when_nothing_did(reviewed):
    assert (
        compute_biological_age(make_db(), ALICE, TODAY)["inputs_hash"]
        == compute_biological_age(make_db(), ALICE, TODAY)["inputs_hash"]
    )


def test_the_fingerprint_changes_when_a_lab_value_is_corrected(reviewed):
    """Otherwise a corrected value would silently reuse a stale number."""
    before = compute_biological_age(make_db(), ALICE, TODAY)["inputs_hash"]
    after = compute_biological_age(
        make_db(panel_rows(rdw=14.4)), ALICE, TODAY)["inputs_hash"]

    assert before != after


def test_the_fingerprint_changes_when_the_catalog_version_does(reviewed, monkeypatch):
    """A range set changed tomorrow must produce a new fingerprint rather than
    quietly reusing today's."""
    before = compute_biological_age(make_db(), ALICE, TODAY)["inputs_hash"]
    monkeypatch.setattr(catalog, "catalog_version", lambda: "global.v2")

    assert compute_biological_age(make_db(), ALICE, TODAY)["inputs_hash"] != before


def test_the_row_written_to_the_table_carries_a_hash_and_not_the_inputs():
    """`score_snapshots` has an `inputs_hash` column and no `inputs` column, and
    that is what makes the review gate hold rather than being a formality: the
    panel values are the user's own and selectable elsewhere, but the row the
    phone reads for a *score* cannot be turned back into the number we declined
    to publish."""
    snapshot = compute_biological_age(make_db(), ALICE, TODAY)

    assert "inputs" not in snapshot
    assert snapshot["inputs_hash"].startswith("sha256:")
    assert snapshot["value"] is None


# ── The review gate, end to end ──────────────────────────────────────────────

def test_nothing_reaches_the_table_while_the_catalog_is_unreviewed():
    snapshot = compute_biological_age(make_db(), ALICE, TODAY)

    assert snapshot["value"] is None
    assert "clinical_review" in snapshot["missing_inputs"]
    assert snapshot["drivers"] == []
    assert snapshot["data_quality"] == NONE


def test_persisting_keyed_on_the_draw_date_replaces_rather_than_accumulates(
    reviewed,
):
    db = make_db()
    snapshot = compute_biological_age(db, ALICE, TODAY)
    persist_snapshot(db, snapshot)
    persist_snapshot(db, compute_biological_age(db, ALICE, TODAY))

    stored = db.table("score_snapshots").select("*").execute().data
    assert len(stored) == 1
    assert stored[0]["as_of_date"] == DRAWN.isoformat()
