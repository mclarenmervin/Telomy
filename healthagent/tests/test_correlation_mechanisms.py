"""The mechanism catalog refuses anything it cannot evidence.

Same discipline as `supplement_rules.py`: validation is loud and happens at
load time, because a pair that can never fire fails invisibly -- the screen
simply shows one fewer pattern and nobody can tell whether that is a quiet
month or a typo.
"""

from pathlib import Path

import pytest
import yaml

from app.analytics import correlation_mechanisms as mech
from app.analytics.correlation_mechanisms import MechanismError

SIGNED = "a" * 64


def write(tmp_path: Path, body: dict) -> Path:
    path = tmp_path / "correlations.test.yaml"
    path.write_text(yaml.safe_dump(body))
    mech.load_pairs.cache_clear()
    mech.pair_for.cache_clear()
    mech.review_status.cache_clear()
    return path


def one(**overrides) -> dict:
    entry = {
        "id": "hrv__sleep_duration",
        "first": "hrv",
        "second": "sleep_duration",
        "verdict": "mechanism",
        "expect": "positive",
        "mechanism": "Sleep restriction lowers overnight parasympathetic tone.",
        "citation": "Tobaldini E et al. Neurosci Biobehav Rev 2017;74:321-329.",
    }
    entry.update(overrides)
    return entry


def file_with(*entries) -> dict:
    return {"version": "correlations.test", "pairs": list(entries)}


# ── The shipped file ─────────────────────────────────────────────────────────

def test_the_shipped_catalog_loads():
    version, pairs = mech.load_pairs()
    assert version
    assert pairs


def test_every_shipped_series_id_is_one_the_engine_can_build():
    _, pairs = mech.load_pairs()
    for pair in pairs.values():
        assert pair.first in mech.SERIES
        assert pair.second in mech.SERIES


def test_the_shipped_catalog_is_not_clinically_reviewed_yet():
    """The same state `biomarkers.v1.yaml` and `supplements.v1.yaml` are in.
    A mechanism sentence is a clinical claim and needs a real name against it;
    until then a correlation is reported as a measured association and the
    explanation is withheld."""
    _, pairs = mech.load_pairs()
    assert not any(mech.review_status(pair_id).reviewed for pair_id in pairs)


# ── What a pair must be ──────────────────────────────────────────────────────

def test_a_pair_naming_an_unknown_series_is_refused(tmp_path):
    path = write(tmp_path, file_with(one(id="hrv__moon_phase", second="moon_phase")))
    with pytest.raises(MechanismError, match="moon_phase"):
        mech.load_pairs(path)


def test_a_mechanism_pair_with_no_citation_is_refused(tmp_path):
    path = write(tmp_path, file_with(one(citation="")))
    with pytest.raises(MechanismError, match="citation"):
        mech.load_pairs(path)


def test_a_mechanism_pair_with_no_expected_direction_is_refused(tmp_path):
    """Without a direction the gate cannot refuse a correlation that runs the
    wrong way, which is the half of plausibility that catches confounders."""
    path = write(tmp_path, file_with(one(expect="")))
    with pytest.raises(MechanismError, match="direction"):
        mech.load_pairs(path)


def test_an_unordered_pair_must_be_declared_in_one_canonical_order(tmp_path):
    """Otherwise the same pair can be declared twice with two verdicts and
    which one applies depends on dictionary order."""
    path = write(tmp_path, file_with(one(id="sleep_duration__hrv", first="sleep_duration", second="hrv")))
    with pytest.raises(MechanismError, match="alphabetical"):
        mech.load_pairs(path)


def test_the_id_must_match_the_two_series(tmp_path):
    path = write(tmp_path, file_with(one(id="something_else")))
    with pytest.raises(MechanismError, match="id"):
        mech.load_pairs(path)


def test_a_pair_declared_twice_is_refused(tmp_path):
    path = write(tmp_path, file_with(one(), one()))
    with pytest.raises(MechanismError, match="twice"):
        mech.load_pairs(path)


def test_a_series_cannot_be_correlated_with_itself(tmp_path):
    path = write(tmp_path, file_with(one(id="hrv__hrv", first="hrv", second="hrv")))
    with pytest.raises(MechanismError):
        mech.load_pairs(path)


# ── Tautological pairs ───────────────────────────────────────────────────────

def test_a_tautological_pair_needs_a_reason_but_no_direction(tmp_path):
    entry = {
        "id": "active_minutes__steps",
        "first": "active_minutes",
        "second": "steps",
        "verdict": "tautological",
        "reason": "Both count the same movement.",
    }
    path = write(tmp_path, file_with(entry))
    _, pairs = mech.load_pairs(path)
    assert pairs["active_minutes__steps"].verdict == mech.TAUTOLOGICAL


def test_a_tautological_pair_may_not_claim_a_direction(tmp_path):
    """It is not a finding at all, so an expected direction would imply the
    engine should report it when the direction matches."""
    entry = {
        "id": "active_minutes__steps",
        "first": "active_minutes",
        "second": "steps",
        "verdict": "tautological",
        "reason": "Both count the same movement.",
        "expect": "positive",
    }
    path = write(tmp_path, file_with(entry))
    with pytest.raises(MechanismError, match="direction"):
        mech.load_pairs(path)


def test_a_tautological_pair_with_no_reason_is_refused(tmp_path):
    entry = {
        "id": "active_minutes__steps",
        "first": "active_minutes",
        "second": "steps",
        "verdict": "tautological",
    }
    path = write(tmp_path, file_with(entry))
    with pytest.raises(MechanismError, match="reason"):
        mech.load_pairs(path)


def test_an_unknown_verdict_is_refused(tmp_path):
    path = write(tmp_path, file_with(one(verdict="probably")))
    with pytest.raises(MechanismError, match="verdict"):
        mech.load_pairs(path)


# ── Which pairs the engine is allowed to test ────────────────────────────────

def test_only_mechanism_pairs_are_testable(tmp_path):
    entry = {
        "id": "active_minutes__steps",
        "first": "active_minutes",
        "second": "steps",
        "verdict": "tautological",
        "reason": "Both count the same movement.",
    }
    path = write(tmp_path, file_with(one(), entry))
    mech.load_pairs(path)
    assert [p.id for p in mech.testable_pairs(path)] == ["hrv__sleep_duration"]


def test_an_undeclared_pair_is_simply_absent(tmp_path):
    path = write(tmp_path, file_with(one()))
    mech.load_pairs(path)
    assert mech.pair_for("steps", "stress", path) is None


def test_a_pair_is_found_whichever_order_it_is_asked_for(tmp_path):
    path = write(tmp_path, file_with(one()))
    mech.load_pairs(path)
    assert mech.pair_for("sleep_duration", "hrv", path).id == "hrv__sleep_duration"
    assert mech.pair_for("hrv", "sleep_duration", path).id == "hrv__sleep_duration"


# ── Sign-off ─────────────────────────────────────────────────────────────────

def test_a_signature_over_edited_content_does_not_count(tmp_path):
    """The withdrawal mechanism, exactly as in the supplement rules: somebody
    changed the mechanism sentence after a clinician signed it, so the
    signature is over words that are no longer there."""
    body = file_with(one())
    body["clinical_review"] = {
        "pairs": [{
            "id": "hrv__sleep_duration",
            "reviewer": "Dr A Reviewer, MCI 12345",
            "reviewed_at": "2026-10-01",
            "content_sha256": SIGNED,
        }]
    }
    path = write(tmp_path, body)
    mech.load_pairs(path)
    assert not mech.review_status("hrv__sleep_duration", path).reviewed


def test_a_signature_naming_a_pair_that_does_not_exist_is_refused(tmp_path):
    """A reviewer's name left in the file against nothing reads like coverage
    we do not have."""
    body = file_with(one())
    body["clinical_review"] = {
        "pairs": [{
            "id": "steps__stress",
            "reviewer": "Dr A Reviewer, MCI 12345",
            "reviewed_at": "2026-10-01",
            "content_sha256": SIGNED,
        }]
    }
    path = write(tmp_path, body)
    with pytest.raises(MechanismError, match="do not exist"):
        mech.load_pairs(path)


def test_a_signature_over_the_true_fingerprint_counts(tmp_path):
    body = file_with(one())
    path = write(tmp_path, body)
    mech.load_pairs(path)
    digest = mech.pair_fingerprint("hrv__sleep_duration", path)

    body["clinical_review"] = {
        "pairs": [{
            "id": "hrv__sleep_duration",
            "reviewer": "Dr A Reviewer, MCI 12345",
            "reviewed_at": "2026-10-01",
            "content_sha256": digest,
        }]
    }
    path = write(tmp_path, body)
    mech.load_pairs(path)
    status = mech.review_status("hrv__sleep_duration", path)
    assert status.reviewed
    assert status.reviewer == "Dr A Reviewer, MCI 12345"
