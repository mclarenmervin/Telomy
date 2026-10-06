"""Readiness parity fixtures — the Python half.

The same files are run by mobile/test/readiness_golden_test.dart. Two
independent implementations agreeing on these inputs is what makes "the port is
identical" a fact rather than a claim, and it is the precondition for changing
the model server-side.

Regenerate with: PYTHONPATH=. .venv/bin/python scripts/build_readiness_golden.py
"""

import json
from datetime import datetime
from pathlib import Path

import pytest

from app.analytics.readiness import calculate
from app.analytics.sleep import Reading

GOLDEN = Path(__file__).resolve().parents[2] / "golden" / "readiness"
TOLERANCE = 1e-6


def fixtures():
    files = sorted(GOLDEN.glob("*.json"))
    assert files, f"no golden fixtures in {GOLDEN}"
    return files


def load(path: Path):
    payload = json.loads(path.read_text())
    readings = [
        Reading(
            m["measurement_type"],
            float(m["value"]),
            datetime.fromisoformat(m["recorded_at"]),
            datetime.fromisoformat(m["ended_at"]) if m.get("ended_at") else None,
        )
        for m in payload["measurements"]
    ]
    return payload, readings


@pytest.mark.parametrize("path", fixtures(), ids=lambda p: p.stem)
def test_python_matches_the_golden_fixture(path):
    payload, readings = load(path)

    result = calculate(
        readings,
        datetime.fromisoformat(payload["date"]),
        sleep_goal=payload["sleep_goal"],
        activity_goal=payload["activity_goal"],
    )
    expected = payload["expected"]

    assert result.score == expected["score"]
    assert result.model_version == expected["model_version"]
    assert sorted(result.missing_inputs) == expected["missing_inputs"]

    got = sorted(
        [{"name": d.name, "score": d.score, "weight": d.weight} for d in result.drivers],
        key=lambda d: d["name"],
    )
    assert [d["name"] for d in got] == [d["name"] for d in expected["drivers"]]
    for actual, want in zip(got, expected["drivers"]):
        assert actual["score"] == pytest.approx(want["score"], abs=TOLERANCE), actual["name"]
        assert actual["weight"] == pytest.approx(want["weight"], abs=TOLERANCE)


def test_the_fixtures_cover_the_cases_a_port_usually_breaks_on():
    """A parity suite that only tests the happy path proves very little."""
    names = {p.stem for p in fixtures()}

    assert {
        "rounding_half_boundary",      # Dart rounds half away from zero
        "overlapping_sleep_sources",   # interval union, not summation
        "bedtime_wraps_midnight",      # the clock wraps
        "zero_baseline",               # division by zero
        "too_sparse_to_score",         # refuses rather than guesses
    } <= names


def test_a_scoreless_fixture_is_present_and_really_has_no_score():
    payload, _ = load(GOLDEN / "too_sparse_to_score.json")

    assert payload["expected"]["score"] is None
