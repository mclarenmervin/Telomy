"""What the agent may know about biological age and epigenetic clocks.

The two are deliberately different kinds of thing and the loader keeps them
apart:

**Biological age is ours.** It is read from `score_snapshots` -- the same row
the app renders -- so a chart and a sentence cannot disagree. It is never
recomputed here, and while the catalog is clinically unreviewed the row carries
no number, which the agent must report as "we cannot say yet" rather than
filling in.

**Epigenetic clocks are not ours.** A Horvath or GrimAge result came from a
third-party provider the user paid. We display and track them; we never compute
one and must never present one as our own output.
"""

from app.common.context_loader import ContextLoader
from tests.fakes import FakeSupabase

USER, OTHER = "user-1", "user-2"


def snapshot(**overrides):
    row = {
        "user_id": USER,
        "score_kind": "biological_age",
        "as_of_date": "2026-06-15",
        "value": 43.2,
        "drivers": [{"name": "rdw", "score": 1.8, "weight": 0.3306,
                     "detail": "13.5 % against an optimal 12.25 %: +1.8 years"}],
        "missing_inputs": [],
        "data_quality": "full",
        "model_version": "biological-age-phenoage-levine-2018-v1",
        "ranges_version": "global.v1",
        "timezone": "Asia/Kolkata",
        "inputs_hash": "sha256:abc",
        "computed_at": "2026-06-16T03:00:00",
    }
    row.update(overrides)
    return row


def clock(**overrides):
    row = {
        "user_id": USER,
        "clock": "horvath",
        "value": 41.3,
        "unit": "years",
        "provider": "TruDiagnostic",
        "collected_at": "2026-03-01T00:00:00+00:00",
        "source": "third_party",
    }
    row.update(overrides)
    return row


# ── Biological age ───────────────────────────────────────────────────────────

def test_the_stored_biological_age_is_what_the_agent_reads():
    """Not a recomputation. The agent must quote the number the user is looking
    at, including its provenance."""
    loader = ContextLoader(FakeSupabase({"score_snapshots": [snapshot()]}))

    out = loader.score_snapshot(USER, "biological_age")

    assert out["status"] == "ok"
    assert out["items"][0]["value"] == 43.2
    assert out["items"][0]["model_version"].startswith("biological-age-phenoage")


def test_the_newest_snapshot_wins():
    loader = ContextLoader(FakeSupabase({"score_snapshots": [
        snapshot(as_of_date="2024-01-10", value=50.0),
        snapshot(as_of_date="2026-06-15", value=43.2),
    ]}))

    assert loader.score_snapshot(USER, "biological_age")["items"][0]["value"] == 43.2


def test_another_user_s_snapshot_is_never_returned():
    loader = ContextLoader(FakeSupabase({"score_snapshots": [
        snapshot(user_id=OTHER, value=99.0)
    ]}))

    assert loader.score_snapshot(USER, "biological_age")["status"] == "empty"


def test_a_withheld_number_comes_back_as_present_but_unknown():
    """While `clinical_review.reviewed` is false the row exists and its value is
    null. "We have not computed this" and "we are not telling you" both have to
    read as unknown, and neither may read as a zero."""
    loader = ContextLoader(FakeSupabase({"score_snapshots": [snapshot(
        value=None, data_quality="none", drivers=[],
        missing_inputs=["clinical_review"],
    )]}))

    item = loader.score_snapshot(USER, "biological_age")["items"][0]

    assert item["value"] is None
    assert "clinical_review" in item["missing_inputs"]


def test_a_user_with_no_snapshot_gets_empty_and_not_unconfigured():
    """"We looked and there is none" is different from "we could not look", and
    the agent is told to keep them apart."""
    loader = ContextLoader(FakeSupabase({"score_snapshots": []}))

    assert loader.score_snapshot(USER, "biological_age")["status"] == "empty"


def test_a_score_kind_we_do_not_compute_is_refused():
    loader = ContextLoader(FakeSupabase({"score_snapshots": [snapshot()]}))

    try:
        loader.score_snapshot(USER, "haemoglobin")
    except ValueError:
        return
    raise AssertionError("an unknown score kind should be refused")


# ── Epigenetic clocks ────────────────────────────────────────────────────────

def test_third_party_clocks_are_returned_with_their_provider():
    """The provider is not decoration. "Your Horvath age is 41.3" without
    saying who measured it invites the user to read it as ours."""
    loader = ContextLoader(FakeSupabase({"epigenetic_results": [clock()]}))

    out = loader.epigenetic_results(USER)

    assert out["status"] == "ok"
    assert out["items"][0]["clock"] == "horvath"
    assert out["items"][0]["provider"] == "TruDiagnostic"
    assert out["items"][0]["source"] == "third_party"


def test_clocks_come_back_newest_first():
    loader = ContextLoader(FakeSupabase({"epigenetic_results": [
        clock(collected_at="2024-01-01T00:00:00+00:00", value=46.0),
        clock(collected_at="2026-03-01T00:00:00+00:00", value=41.3),
    ]}))

    values = [c["value"] for c in loader.epigenetic_results(USER)["items"]]

    assert values == [41.3, 46.0]


def test_several_clocks_are_all_returned_rather_than_reconciled():
    """Horvath, Hannum and GrimAge disagree by years on the same sample, and
    that is a property of the clocks, not an error to average away."""
    loader = ContextLoader(FakeSupabase({"epigenetic_results": [
        clock(clock="horvath", value=41.3),
        clock(clock="grimage", value=48.1),
        clock(clock="dunedinpace", value=0.92, unit="pace"),
    ]}))

    out = loader.epigenetic_results(USER)

    assert {c["clock"] for c in out["items"]} == {"horvath", "grimage", "dunedinpace"}


def test_a_pace_clock_keeps_its_own_unit():
    """DunedinPACE is a rate of ageing, not an age. Rendering 0.92 as "0.92
    years old" is the obvious way to get this wrong."""
    loader = ContextLoader(FakeSupabase({"epigenetic_results": [
        clock(clock="dunedinpace", value=0.92, unit="pace")
    ]}))

    assert loader.epigenetic_results(USER)["items"][0]["unit"] == "pace"


def test_another_user_s_clocks_are_never_returned():
    loader = ContextLoader(FakeSupabase({"epigenetic_results": [
        clock(user_id=OTHER, value=99.0)
    ]}))

    assert loader.epigenetic_results(USER)["status"] == "empty"


def test_no_clocks_is_empty_rather_than_an_error():
    loader = ContextLoader(FakeSupabase({"epigenetic_results": []}))

    assert loader.epigenetic_results(USER) == {"status": "empty", "items": []}
