"""The score envelope.

One shape for every score, carrying enough to answer "where did this number
come from" without re-deriving it: the model that produced it, the range set it
graded against, the day it describes, the timezone that defined that day, what
was missing, and a hash of the inputs.

The hash is what makes a stored number reproducible. Recomputing a snapshot
from its own inputs must give byte-identical output, so a model or range change
tomorrow produces a NEW snapshot rather than silently rewriting one the user has
already read.
"""

from datetime import date, datetime

import pytest

from app.analytics.readiness import Driver, Readiness
from app.analytics.score_snapshot import (
    FULL,
    NONE,
    PARTIAL,
    build_snapshot,
    inputs_hash,
)

AS_OF = date(2026, 10, 1)
COMPUTED_AT = datetime(2026, 10, 2, 3, 0)


def readiness(score=72, drivers=(("HRV", 80.0, 0.22),), missing=()):
    return Readiness(
        score=score,
        drivers=[Driver(n, s, w, "detail") for n, s, w in drivers],
        missing_inputs=list(missing),
        recommendation="Moderate readiness estimate",
    )


def build(result, **kwargs):
    options = {
        "user_id": "u1",
        "kind": "readiness",
        "as_of": AS_OF,
        "timezone": "Asia/Kolkata",
        "inputs": {"readings": 120},
        "computed_at": COMPUTED_AT,
    }
    options.update(kwargs)
    return build_snapshot(result, **options)


def test_the_envelope_carries_the_number_and_its_provenance():
    snapshot = build(readiness())

    assert snapshot["score_kind"] == "readiness"
    assert snapshot["value"] == 72
    assert snapshot["model_version"] == "readiness-v1"
    assert snapshot["as_of_date"] == "2026-10-01"
    assert snapshot["timezone"] == "Asia/Kolkata"
    assert snapshot["computed_at"] == COMPUTED_AT.isoformat()


def test_drivers_are_carried_so_the_screen_need_not_recompute_them():
    snapshot = build(readiness(drivers=(("HRV", 80.0, 0.22), ("Stress", 70.0, 0.08))))

    assert [d["name"] for d in snapshot["drivers"]] == ["HRV", "Stress"]
    assert snapshot["drivers"][0]["score"] == 80.0
    assert snapshot["drivers"][0]["weight"] == 0.22


def test_a_complete_score_is_full_quality():
    assert build(readiness())["data_quality"] == FULL


def test_a_score_with_missing_inputs_is_partial_and_says_which():
    snapshot = build(readiness(missing=("Sleep duration", "Stress")))

    assert snapshot["data_quality"] == PARTIAL
    assert snapshot["missing_inputs"] == ["Sleep duration", "Stress"]


def test_no_score_is_quality_none_not_a_zero():
    """A zero readiness and an unknown readiness are different statements."""
    snapshot = build(readiness(score=None, drivers=(), missing=("HRV",)))

    assert snapshot["value"] is None
    assert snapshot["data_quality"] == NONE


def test_the_inputs_hash_is_stable_across_runs():
    first = build(readiness())
    second = build(readiness())

    assert first["inputs_hash"] == second["inputs_hash"]


def test_the_inputs_hash_ignores_key_order():
    """Otherwise a dict reordering looks like the user's data changed."""
    assert inputs_hash({"a": 1, "b": 2}) == inputs_hash({"b": 2, "a": 1})


def test_the_inputs_hash_changes_when_the_inputs_change():
    assert build(readiness())["inputs_hash"] != build(
        readiness(), inputs={"readings": 121}
    )["inputs_hash"]


def test_the_hash_is_labelled_with_its_algorithm():
    assert build(readiness())["inputs_hash"].startswith("sha256:")


def test_the_ranges_version_is_recorded_when_one_applied():
    snapshot = build(readiness(), ranges_version="global.v1")

    assert snapshot["ranges_version"] == "global.v1"


def test_a_score_that_used_no_ranges_records_none_rather_than_pretending():
    """Readiness grades against personal baselines, not reference ranges."""
    assert build(readiness())["ranges_version"] is None


def test_the_snapshot_is_json_serialisable():
    import json

    json.dumps(build(readiness()))


def test_the_primary_key_fields_are_present_for_upsert():
    snapshot = build(readiness())

    assert {"user_id", "score_kind", "as_of_date"} <= set(snapshot)
