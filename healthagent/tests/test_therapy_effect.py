"""Before/after evidence for a therapy, and when there is not enough of it.

Today a sauna is a journal entry with a free-text note. The question this
module answers is "what do YOUR sauna sessions do to you", and the ways of
answering it wrongly are the same three as for correlations -- too few
sessions, too many metrics tested at once, and an effect with no mechanism --
plus one that is specific to therapies: the session is not the only thing that
happened.
"""

from datetime import datetime, timedelta, timezone

import pytest
import yaml

from app.analytics import therapy_catalog, therapy_effect
from app.analytics.event_analysis import Reading
from app.analytics.therapy_catalog import TherapyCatalogError
from app.analytics.therapy_effect import (
    HELPED,
    IN_SESSION_ONLY,
    MIN_SESSIONS,
    NO_RELIABLE_SIGNAL,
    NOT_SIGNIFICANT,
    POSSIBLE_NEGATIVE,
    PROMISING,
    TOO_EARLY,
    TOO_FEW_SESSIONS,
    DIRECTION_MISMATCH,
    classify_verdict,
    effects_for,
)

UTC = timezone.utc
BASE = datetime(2026, 7, 1, 12, 0, tzinfo=UTC)


def session(day: int, minutes: int = 20):
    start = BASE + timedelta(days=day)
    return {
        "id": f"e{day}",
        "event_type": "sauna",
        "started_at": start.isoformat(),
        "ended_at": (start + timedelta(minutes=minutes)).isoformat(),
    }


def readings_for(sessions, *, before, after, baseline, metric="heartRate"):
    """A reading an hour each side of every session, plus a flat baseline
    stretching back a fortnight so `analyze_event` has something to compare
    against."""
    out = []
    for index, raw in enumerate(sessions):
        start = datetime.fromisoformat(raw["started_at"])
        end = datetime.fromisoformat(raw["ended_at"])
        out.append(Reading(metric, before[index], start - timedelta(minutes=30)))
        out.append(Reading(metric, after[index], end + timedelta(minutes=30)))
        for back in range(1, 15):
            # Five hours back, not one: at exactly one hour the reading lands
            # on the boundary of the before-window of a session three days
            # earlier, and the fixture quietly fills its own before-windows
            # with baseline values.
            out.append(
                Reading(metric, baseline, start - timedelta(days=back, hours=5))
            )
    return out


def flat(value, n):
    return [value] * n


def test_the_six_verdicts_and_downgrades_are_reversible():
    assert classify_verdict([8, 9, 7, 8, 9, 10, 8, 9], "increase", 0.01)["verdict"] == HELPED
    # Strong overall, but the first half disagrees: this cannot be Helped.
    assert classify_verdict([-1] * 10 + [100] * 10, "increase", 0.01)["verdict"] == PROMISING
    assert classify_verdict([-9, -8, -10, -7, -9, -8], "increase", 0.01)["verdict"] == POSSIBLE_NEGATIVE
    assert classify_verdict([-2, 2, -1, 1, 0, 1], "increase", 0.9)["verdict"] == NO_RELIABLE_SIGNAL
    assert classify_verdict([1, 2, 1, 2], "increase", None)["verdict"] == TOO_EARLY
    assert classify_verdict([], "increase", None)["verdict"] == IN_SESSION_ONLY


def test_verdict_carries_effect_interval_replication_coverage_and_provenance():
    sessions = [session(d * 3) for d in range(8)]
    result = effects_for(sessions, readings_for(
        sessions, before=flat(60, 8), after=flat(76, 8), baseline=60,
    ))
    row = result["verdicts"][0]
    assert row["verdict"] == HELPED
    assert row["ci_low"] > 0
    assert row["q_value"] <= 0.1
    assert row["replicated"] is True
    assert row["wearable_coverage"] == 1
    assert row["provenance"]["model_version"] == therapy_effect.MODEL_VERSION


# ── The catalog ──────────────────────────────────────────────────────────────

def test_the_shipped_catalog_loads():
    version, modalities = therapy_catalog.load_modalities()
    assert version
    assert "sauna" in modalities


def test_every_declared_metric_is_one_the_event_analysis_tracks():
    from app.analytics.event_analysis import TRACKED

    _, modalities = therapy_catalog.load_modalities()
    for modality in modalities.values():
        for effect in modality.effects:
            assert effect.metric in TRACKED


def test_the_shipped_catalog_is_not_clinically_reviewed_yet():
    _, modalities = therapy_catalog.load_modalities()
    for modality in modalities.values():
        for effect in modality.effects:
            assert not therapy_catalog.review_status(
                modality.id, effect.metric
            ).reviewed


def test_an_effect_on_an_untracked_metric_is_refused(tmp_path):
    path = tmp_path / "t.yaml"
    path.write_text(yaml.safe_dump({
        "version": "t", "modalities": [{
            "id": "sauna", "label": "sauna", "category": "heat",
            "summary": "test", "intended_experience": "test",
            "event_types": ["sauna"],
            "dose_schema": {"duration_minutes": {"minimum": 1}},
            "contraindication_rule_ids": [],
            "effects": [{"metric": "mood", "expect": "increase",
                         "mechanism": "m", "citation": "c"}],
        }], "clinical_review": {"effects": []},
    }))
    therapy_catalog.load_modalities.cache_clear()
    with pytest.raises(TherapyCatalogError, match="mood"):
        therapy_catalog.load_modalities(path)
    therapy_catalog.load_modalities.cache_clear()


def test_an_effect_with_no_expected_direction_is_refused(tmp_path):
    path = tmp_path / "t.yaml"
    path.write_text(yaml.safe_dump({
        "version": "t", "modalities": [{
            "id": "sauna", "label": "sauna", "category": "heat",
            "summary": "test", "intended_experience": "test",
            "event_types": ["sauna"],
            "dose_schema": {"duration_minutes": {"minimum": 1}},
            "contraindication_rule_ids": [],
            "effects": [{"metric": "heartRate", "mechanism": "m", "citation": "c"}],
        }], "clinical_review": {"effects": []},
    }))
    therapy_catalog.load_modalities.cache_clear()
    with pytest.raises(TherapyCatalogError, match="direction"):
        therapy_catalog.load_modalities(path)
    therapy_catalog.load_modalities.cache_clear()


def test_a_modality_with_no_event_type_can_never_fire(tmp_path):
    path = tmp_path / "t.yaml"
    path.write_text(yaml.safe_dump({
        "version": "t", "modalities": [{
            "id": "hbot", "label": "hyperbaric oxygen", "category": "oxygen",
            "summary": "test", "intended_experience": "test",
            "event_types": [],
            "dose_schema": {"duration_minutes": {"minimum": 1}},
            "contraindication_rule_ids": [],
            "effects": [{"metric": "spo2", "expect": "increase",
                         "mechanism": "m", "citation": "c"}],
        }], "clinical_review": {"effects": []},
    }))
    therapy_catalog.load_modalities.cache_clear()
    with pytest.raises(TherapyCatalogError, match="event type"):
        therapy_catalog.load_modalities(path)
    therapy_catalog.load_modalities.cache_clear()


# ── How many sessions it takes ───────────────────────────────────────────────

def test_one_session_is_a_story_and_not_evidence():
    sessions = [session(0)]
    result = effects_for(
        sessions,
        readings_for(sessions, before=[60], after=[85], baseline=60),
    )
    assert result["reported"] == []
    assert result["withheld"][0]["withheld"] == TOO_FEW_SESSIONS


def test_a_run_short_of_the_floor_is_not_counted_as_a_test():
    sessions = [session(d * 3) for d in range(MIN_SESSIONS - 1)]
    n = len(sessions)
    result = effects_for(
        sessions,
        readings_for(sessions, before=flat(60, n), after=flat(85, n), baseline=60),
    )
    assert result["tested"] == 0


def test_a_consistent_rise_across_enough_sessions_is_reported():
    sessions = [session(d * 3) for d in range(8)]
    before = [58, 61, 59, 62, 60, 57, 63, 60]
    after = [74, 78, 73, 80, 76, 72, 81, 77]
    result = effects_for(
        sessions, readings_for(sessions, before=before, after=after, baseline=60)
    )
    reported = [r for r in result["reported"] if r["metric"] == "heartRate"]
    assert len(reported) == 1
    assert reported[0]["modality"] == "sauna"
    assert reported[0]["mean_delta"] > 10
    assert reported[0]["sessions"] == 8


def test_sessions_that_move_the_needle_both_ways_are_not_an_effect():
    sessions = [session(d * 3) for d in range(8)]
    before = [60] * 8
    after = [75, 46, 71, 48, 69, 50, 73, 47]
    result = effects_for(
        sessions, readings_for(sessions, before=before, after=after, baseline=60)
    )
    assert result["reported"] == []
    assert any(r["withheld"] == NOT_SIGNIFICANT for r in result["withheld"])


# ── Plausibility ─────────────────────────────────────────────────────────────

def test_an_effect_running_against_its_mechanism_is_refused():
    """A sauna is expected to raise heart rate. Sessions that consistently
    LOWER it are something else happening around the sauna, and reporting it
    under the heat-stress mechanism would be the convincing way to be wrong."""
    sessions = [session(d * 3) for d in range(8)]
    before = [78, 80, 76, 82, 79, 77, 81, 78]
    after = [60, 62, 59, 63, 61, 58, 64, 60]
    result = effects_for(
        sessions, readings_for(sessions, before=before, after=after, baseline=70)
    )
    assert result["reported"] == []
    assert any(r["withheld"] == DIRECTION_MISMATCH for r in result["withheld"])


def test_a_metric_no_modality_declares_is_never_tested():
    """spo2 is tracked and is not a declared sauna effect, so no number about
    it ever reaches a user however cleanly it moved."""
    sessions = [session(d * 3) for d in range(8)]
    n = len(sessions)
    readings = readings_for(
        sessions, before=flat(97, n), after=flat(91, n), baseline=97, metric="spo2"
    )
    result = effects_for(sessions, readings)
    assert all(r["metric"] != "spo2" for r in result["reported"] + result["withheld"])


def test_an_unreviewed_mechanism_is_withheld_but_the_change_is_not():
    sessions = [session(d * 3) for d in range(8)]
    before = [58, 61, 59, 62, 60, 57, 63, 60]
    after = [74, 78, 73, 80, 76, 72, 81, 77]
    result = effects_for(
        sessions, readings_for(sessions, before=before, after=after, baseline=60)
    )
    reported = result["reported"][0]
    assert reported["mechanism"] is None
    assert reported["mechanism_reviewed"] is False


# ── The session is not the only thing that happened ──────────────────────────

def test_a_session_overlapping_another_event_is_excluded():
    """A sauna taken straight after a workout measures the workout. This is
    the confounder specific to therapies, and `analyze_event` already
    excludes other events from the baseline -- the session itself has to be
    excluded too."""
    sessions = [session(d * 3) for d in range(8)]
    n = len(sessions)
    overlapping = [
        (
            datetime.fromisoformat(sessions[0]["started_at"]) - timedelta(minutes=20),
            datetime.fromisoformat(sessions[0]["ended_at"]) + timedelta(minutes=5),
        )
    ]
    result = effects_for(
        sessions,
        readings_for(sessions, before=flat(60, n), after=flat(80, n), baseline=60),
        other_events=overlapping,
    )
    assert result["reported"][0]["sessions"] == 7


def test_no_sessions_at_all_is_an_empty_result_rather_than_a_failure():
    result = effects_for([], [])
    assert result["reported"] == []
    assert result["tested"] == 0


def test_the_result_names_the_model_and_the_catalog_version():
    result = effects_for([], [])
    assert result["model_version"] == therapy_effect.MODEL_VERSION
    assert result["catalog_version"]


def test_a_week_when_everything_was_elevated_is_not_an_effect():
    """Each session is its own control. Illness, heat or a hard training
    block lifts both the before and the after, and the difference is what is
    tested -- which is also why no baseline reading is needed."""
    sessions = [session(d * 3) for d in range(8)]
    # Every session's pair is 15 apart, but the level wanders by 20.
    before = [60, 62, 80, 78, 61, 59, 77, 81]
    after = [75, 77, 95, 93, 76, 74, 92, 96]
    result = effects_for(
        sessions, readings_for(sessions, before=before, after=after, baseline=60)
    )
    reported = [r for r in result["reported"] if r["metric"] == "heartRate"]
    assert reported[0]["mean_delta"] == pytest.approx(15.0)


def test_the_effect_is_computed_without_any_baseline_readings():
    """Only the two hours around each session are read. A fortnight of a
    wearable's stream per session would make the feature unaffordable, and
    the arithmetic does not need it."""
    sessions = [session(d * 3) for d in range(8)]
    n = len(sessions)
    narrow = []
    for index, raw in enumerate(sessions):
        start = datetime.fromisoformat(raw["started_at"])
        end = datetime.fromisoformat(raw["ended_at"])
        narrow.append(Reading("heartRate", 60, start - timedelta(minutes=30)))
        narrow.append(Reading("heartRate", 76, end + timedelta(minutes=30)))

    result = effects_for(sessions, narrow)

    reported = [r for r in result["reported"] if r["metric"] == "heartRate"]
    assert len(reported) == 1
    assert reported[0]["mean_delta"] == pytest.approx(16.0)


# ── The seam ─────────────────────────────────────────────────────────────────

def _db_with_sessions(user_id, count=8, before=60, after=76, other=None):
    from tests.fakes import FakeSupabase

    events, measurements = [], []
    for index in range(count):
        start = BASE - timedelta(days=index * 3)
        end = start + timedelta(minutes=20)
        events.append({
            "id": f"s{index}", "user_id": user_id, "event_type": "sauna",
            "status": "ended", "started_at": start.isoformat(),
            "ended_at": end.isoformat(),
        })
        for stamp, value in (
            (start - timedelta(minutes=30), before),
            (end + timedelta(minutes=30), after),
        ):
            measurements.append({
                "user_id": user_id, "measurement_type": "heartRate",
                "value": value, "recorded_at": stamp.isoformat(),
            })
    return FakeSupabase({
        "events": events + (other or []),
        "health_measurements": measurements,
    })


def test_for_user_reads_everything_through_the_scoped_loader():
    from app.common.context_loader import ContextLoader
    from app.analytics.therapy_effect import for_user

    user = "00000000-0000-0000-0000-0000000000aa"
    loader = ContextLoader(_db_with_sessions(user))

    result = for_user(loader, user)

    reported = [r for r in result["reported"] if r["metric"] == "heartRate"]
    assert reported[0]["modality"] == "sauna"
    assert reported[0]["sessions"] == 8


def test_another_users_sessions_are_not_reachable():
    from app.common.context_loader import ContextLoader
    from app.analytics.therapy_effect import for_user

    loader = ContextLoader(_db_with_sessions("00000000-0000-0000-0000-0000000000bb"))

    result = for_user(loader, "00000000-0000-0000-0000-0000000000aa")

    assert result["tested"] == 0
    assert result["reported"] == []


def test_a_session_the_user_rejected_is_not_analysed():
    """Somebody who tapped sauna by mistake and said so must not have it
    measured anyway."""
    from app.common.context_loader import ContextLoader

    user = "00000000-0000-0000-0000-0000000000aa"
    db = _db_with_sessions(user)
    for row in db.tables["events"]:
        row["status"] = "rejected"
    loader = ContextLoader(db)

    assert loader.therapy_sessions(user, ["sauna"])["items"] == []


def test_a_session_still_running_has_no_after_to_measure():
    from app.common.context_loader import ContextLoader

    user = "00000000-0000-0000-0000-0000000000aa"
    db = _db_with_sessions(user)
    db.tables["events"][0]["ended_at"] = None
    loader = ContextLoader(db)

    assert len(loader.therapy_sessions(user, ["sauna"])["items"]) == 7


def test_a_therapy_is_not_a_confounder_of_itself():
    """Every sauna overlaps a sauna. Without excluding the modality's own
    event types, every session would be dropped as confounded and the
    feature would report nothing, forever, silently."""
    from app.common.context_loader import ContextLoader
    from app.analytics.therapy_effect import for_user

    user = "00000000-0000-0000-0000-0000000000aa"
    result = for_user(ContextLoader(_db_with_sessions(user)), user)

    assert result["reported"][0]["sessions"] == 8
    assert result["reported"][0]["sessions_confounded"] == 0


def test_the_app_has_a_label_for_every_signal_the_engine_tracks():
    """Cross-language drift check. A metric the engine reports and the app
    has no label for renders as `heartRate` on a card -- F4 shipped "Rdw" and
    "Hs crp" to a real screen with every test on both sides green."""
    import re
    from pathlib import Path

    from app.analytics.event_analysis import TRACKED

    source = (
        Path(__file__).resolve().parents[2]
        / "mobile" / "lib" / "features" / "therapies" / "models"
        / "therapy_effect.dart"
    ).read_text()
    block = source.split("const metricLabels = <String, String>{", 1)[1].split("};", 1)[0]
    labelled = set(re.findall(r"'(\w+)':", block))

    assert set(TRACKED) <= labelled
