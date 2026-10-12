"""One view over five files that each describe their sign-offs differently.

The five reviewed-content catalogs grew one per phase, and each ended up with
its own vocabulary for the same three facts: the block key is `markers`,
`rules`, `pairs`, `effects` or `variants`; the entry key is `id` in four of
them and `rsid` in the fifth; and the fingerprint function is called
`marker_fingerprint`, `rule_fingerprint`, `pair_fingerprint`,
`effect_fingerprint` or `variant_fingerprint`.

That is fine inside each engine and useless to a surface whose whole job is
"show me everything nobody has signed". This module is the uniform view, and
the property worth testing hardest is that it agrees with each engine about
what the hash is — because if the admin surface computed a fingerprint
differently from the loader, it would collect a signature the loader then
refused to honour, which is the most expensive possible way to waste a
clinician's time.

The round-trip test is the one that proves the surface closes the loop: take
an unsigned entry, render the block the admin surface would hand somebody to
commit, write it into the file, and assert the engine's own `review_status`
now says reviewed.
"""

import pytest
import yaml

from app.analytics import (
    catalog,
    correlation_mechanisms,
    supplement_rules,
    therapy_catalog,
    variant_catalog,
)
from app.clinical import reviewable

CATALOGUE_NAMES = ("biomarkers", "supplements", "correlations", "therapies",
                   "variants")


@pytest.fixture(autouse=True)
def _clear_caches():
    reviewable.clear_caches()
    yield
    reviewable.clear_caches()


def by_name(name: str):
    return next(c for c in reviewable.catalogues() if c.name == name)


# ── All five, described the same way ─────────────────────────────────────────

def test_all_five_reviewable_catalogues_are_registered():
    """F8 added three of these. A sixth arriving and not appearing here is how
    the surface silently stops covering the thing it exists for."""
    assert tuple(c.name for c in reviewable.catalogues()) == CATALOGUE_NAMES


def test_every_catalogue_names_the_file_a_human_has_to_commit():
    for entry in reviewable.catalogues():
        assert entry.path.endswith(".yaml")
        assert entry.name in entry.path


def test_every_catalogue_reports_its_own_version():
    assert by_name("biomarkers").version == catalog.catalog_version()
    assert by_name("supplements").version == supplement_rules.rules_version()
    assert by_name("correlations").version == correlation_mechanisms.pairs_version()
    assert by_name("therapies").version == therapy_catalog.catalog_version()
    assert by_name("variants").version == variant_catalog.variants_version()


def test_every_catalogue_has_entries_to_sign():
    """A catalog with no entries would report "fully signed" and be wrong in
    the most reassuring possible direction."""
    for entry in reviewable.catalogues():
        assert entry.entries, f"{entry.name} declares nothing reviewable"


def test_every_entry_carries_something_a_clinician_can_read():
    """An id is not a thing to take a clinical view on. Somebody asked to put
    their registration number against `rs1801133` needs to be told it is
    MTHFR and what the sentence says."""
    for entry in reviewable.catalogues():
        for item in entry.entries:
            assert item.entry_id
            assert item.label and item.label != item.entry_id


# ── The fingerprint is the engine's own ──────────────────────────────────────

def test_every_fingerprint_is_a_sha256():
    for entry in reviewable.catalogues():
        for item in entry.entries:
            assert len(item.fingerprint) == 64
            assert item.fingerprint == item.fingerprint.lower()


@pytest.mark.parametrize("name,engine_fingerprint", [
    ("biomarkers", lambda i: catalog.marker_fingerprint(i)),
    ("supplements", lambda i: supplement_rules.rule_fingerprint(i)),
    ("correlations", lambda i: correlation_mechanisms.pair_fingerprint(i)),
    ("therapies", lambda i: therapy_catalog.effect_fingerprint(i)),
    ("variants", lambda i: variant_catalog.variant_fingerprint(i)),
])
def test_the_surface_and_the_engine_agree_on_what_would_be_signed(
    name, engine_fingerprint
):
    """The expensive failure. A surface that hashed an entry differently from
    the loader would collect a real signature from a real clinician that the
    loader then refused to honour, and the symptom would be a screen still
    saying nobody has reviewed this."""
    for item in by_name(name).entries:
        assert item.fingerprint == engine_fingerprint(item.entry_id), item.entry_id


# ── Signed, and bound to what was signed ─────────────────────────────────────

def test_the_counts_add_up():
    totals = reviewable.summary()
    for entry in reviewable.catalogues():
        counted = totals["catalogues"][entry.name]
        assert counted["total"] == len(entry.entries)
        assert counted["signed"] + counted["unsigned"] == counted["total"]
    assert totals["unsigned"] == sum(
        c["unsigned"] for c in totals["catalogues"].values()
    )


def test_pending_is_exactly_what_is_not_signed():
    pending = reviewable.pending()
    assert len(pending) == reviewable.summary()["unsigned"]
    assert all(not item.signed for item in pending)


HBA1C = """- id: hba1c
  name: HbA1c
  system: metabolic
  canonical_unit: "%"
  units:
    "%": 1.0
  standard: [4.0, 5.6]
  optimal: [4.8, 5.2]
  critical: [3.0, 15.0]
  citation: "ADA Standards of Care"
"""


def write_biomarkers(tmp_path, monkeypatch, review_block, markers=HBA1C):
    path = tmp_path / "biomarkers.v1.yaml"
    path.write_text(f"version: test.v1\n{review_block}biomarkers:\n{markers}")
    monkeypatch.setattr(catalog, "CATALOG_PATH", path)
    for cache in (catalog.load_catalog, catalog.review_status, catalog.alias_index):
        cache.cache_clear()
    reviewable.clear_caches()
    return path


UNSIGNED_BLOCK = """clinical_review:
  reviewed: false
  reviewer:
  reviewed_at:
  markers: []
"""


def test_an_entry_with_no_signature_is_unsigned(tmp_path, monkeypatch):
    write_biomarkers(tmp_path, monkeypatch, UNSIGNED_BLOCK)

    item = by_name("biomarkers").entries[0]

    assert item.entry_id == "hba1c"
    assert not item.signed
    assert item.reviewer is None


def test_a_signature_over_the_current_content_reads_as_signed(
    tmp_path, monkeypatch
):
    write_biomarkers(tmp_path, monkeypatch, UNSIGNED_BLOCK)
    digest = by_name("biomarkers").entries[0].fingerprint

    write_biomarkers(tmp_path, monkeypatch, f"""clinical_review:
  reviewed: false
  reviewer:
  reviewed_at:
  markers:
    - id: hba1c
      reviewer: "Dr A. Rao, KMC/12345"
      reviewed_at: "2026-10-12"
      content_sha256: "{digest}"
""")

    item = by_name("biomarkers").entries[0]

    assert item.signed
    assert item.reviewer == "Dr A. Rao, KMC/12345"
    assert item.reviewed_at == "2026-10-12"


def test_editing_the_entry_afterwards_withdraws_the_signature(
    tmp_path, monkeypatch
):
    """The property the whole hash scheme exists for, seen from the surface:
    an edited range reappears in the pending list rather than carrying a
    signature nobody gave it."""
    write_biomarkers(tmp_path, monkeypatch, UNSIGNED_BLOCK)
    digest = by_name("biomarkers").entries[0].fingerprint
    signed_block = f"""clinical_review:
  reviewed: false
  reviewer:
  reviewed_at:
  markers:
    - id: hba1c
      reviewer: "Dr A. Rao, KMC/12345"
      reviewed_at: "2026-10-12"
      content_sha256: "{digest}"
"""
    write_biomarkers(tmp_path, monkeypatch, signed_block)
    assert by_name("biomarkers").entries[0].signed

    moved = HBA1C.replace("optimal: [4.8, 5.2]", "optimal: [4.8, 5.4]")
    write_biomarkers(tmp_path, monkeypatch, signed_block, markers=moved)

    assert not by_name("biomarkers").entries[0].signed


# ── The block the admin surface hands somebody to commit ─────────────────────

def test_the_block_lands_under_the_key_that_catalogue_uses():
    """Four of the five say `id` under their own block key; variants say
    `rsid`. Getting this wrong produces a file the loader rejects at import,
    which at least fails loudly — but it fails after a clinician has signed."""
    expected = {
        "biomarkers": ("markers", "id"),
        "supplements": ("rules", "id"),
        "correlations": ("pairs", "id"),
        "therapies": ("effects", "id"),
        "variants": ("variants", "rsid"),
    }
    for name, (block_key, id_key) in expected.items():
        entry = by_name(name)
        assert entry.review_key == block_key
        assert entry.id_key == id_key


def test_the_rendered_block_is_valid_yaml_naming_the_signatory():
    item = by_name("variants").entries[0]

    block = reviewable.signoff_block("variants", [
        reviewable.Signature(
            entry_id=item.entry_id,
            content_sha256=item.fingerprint,
            reviewer="Dr A. Rao, KMC/12345",
            reviewed_at="2026-10-12",
        )
    ])
    parsed = yaml.safe_load(block)

    row = parsed["clinical_review"]["variants"][0]
    assert row["rsid"] == item.entry_id
    assert row["content_sha256"] == item.fingerprint
    assert row["reviewer"] == "Dr A. Rao, KMC/12345"
    assert row["reviewed_at"] == "2026-10-12"


def test_a_block_for_content_that_has_moved_is_refused():
    """The surface renders what was signed, and what was signed has to still
    be there. Rendering a stale hash would produce a block that looks
    committed and does nothing."""
    item = by_name("variants").entries[0]

    with pytest.raises(reviewable.StaleSignature):
        reviewable.signoff_block("variants", [
            reviewable.Signature(
                entry_id=item.entry_id,
                content_sha256="0" * 64,
                reviewer="Dr A. Rao, KMC/12345",
                reviewed_at="2026-10-12",
            )
        ])


def test_a_block_for_an_entry_nobody_declared_is_refused():
    with pytest.raises(reviewable.StaleSignature):
        reviewable.signoff_block("variants", [
            reviewable.Signature(
                entry_id="rs000000000",
                content_sha256="0" * 64,
                reviewer="Dr A. Rao, KMC/12345",
                reviewed_at="2026-10-12",
            )
        ])


def test_the_block_round_trips_through_the_engine(tmp_path, monkeypatch):
    """The whole surface, end to end: an unsigned entry, the block the admin
    hands over, and the engine honouring it afterwards.

    Without this, every other test here could pass while the rendered YAML
    was subtly the wrong shape, and nobody would find out until a clinician
    had signed something for nothing.
    """
    write_biomarkers(tmp_path, monkeypatch, UNSIGNED_BLOCK)
    item = by_name("biomarkers").entries[0]
    assert not catalog.review_status("hba1c").reviewed

    block = reviewable.signoff_block("biomarkers", [
        reviewable.Signature(
            entry_id=item.entry_id,
            content_sha256=item.fingerprint,
            reviewer="Dr A. Rao, KMC/12345",
            reviewed_at="2026-10-12",
        )
    ])

    write_biomarkers(tmp_path, monkeypatch, block)
    review = catalog.review_status("hba1c")

    assert review.reviewed
    assert review.reviewer == "Dr A. Rao, KMC/12345"
    assert review.reviewed_at == "2026-10-12"
