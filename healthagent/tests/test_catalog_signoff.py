"""Signing off the catalog, one marker at a time, bound to what was signed.

The handoff leaves F5 one open decision: biological age is built, tested and
withheld because `biomarkers.v1.yaml` says `reviewed: false`, and flipping it is
"a hand-edit to a YAML file with no process around it". This is the process.

Two changes, and both are about making the signature mean something.

**Per marker, not all or nothing.** Biological age needs nine markers. The
catalog carries thirty-three. Requiring the whole file to be reviewed before
any of it can be used means the cheapest useful sign-off is four times larger
than it needs to be, and in practice that means it does not happen. A clinician
can now sign the nine PhenoAge markers and unblock biological age without
taking a view on cortisol.

**Bound to a content hash.** A signature over "hba1c" is a signature over a
name. A signature over a fingerprint of hba1c's entry is a signature over the
ranges, the units, the conversions, the aliases and the citation — so editing
any of them afterwards invalidates the sign-off automatically rather than
silently inheriting it. This is the part that makes the audit trail real: the
git diff shows the range changed, and the loader stops trusting the signature
in the same commit.

The catalog-level block still works and still means "all of it", so nothing
about today's behaviour changes.
"""

import pytest

from app.analytics import catalog
from app.analytics.catalog import CatalogError, load_catalog, marker_fingerprint
from app.analytics.reference_ranges import OPTIMAL, UNGRADED, RangeResolver, grade_for_display


@pytest.fixture(autouse=True)
def _clear_caches():
    _clear()
    yield
    _clear()


def _clear():
    """`review_status` is the only cached one of the three; the other two
    re-read the file, so these two clears reach all of it."""
    for cache in (load_catalog, catalog.review_status, catalog.alias_index):
        cache.cache_clear()


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

FERRITIN = """- id: ferritin
  name: Ferritin
  system: haematology
  canonical_unit: "ng/mL"
  units:
    "ng/mL": 1.0
  standard: [30.0, 300.0]
  optimal: [50.0, 150.0]
  critical: [5.0, 1500.0]
  citation: "WHO iron status guidance"
"""

UNREVIEWED = """clinical_review:
  reviewed: false
  reviewer:
  reviewed_at:
"""

FULLY_REVIEWED = """clinical_review:
  reviewed: true
  reviewer: "Dr A. Example, MBBS MD, reg. 12345"
  reviewed_at: "2026-10-09"
"""


def signed_markers(*entries) -> str:
    """A `clinical_review` block signing off the given (marker_id, hash) pairs,
    with the catalog-level block still saying false."""
    rows = "".join(
        f'''    - id: {marker_id}
      reviewer: "Dr A. Example, MBBS MD, reg. 12345"
      reviewed_at: "2026-10-09"
      content_sha256: "{fingerprint}"
'''
        for marker_id, fingerprint in entries
    )
    return f"""clinical_review:
  reviewed: false
  reviewer:
  reviewed_at:
  markers:
{rows}"""


def write_catalog(tmp_path, monkeypatch, review_block: str, markers: str = HBA1C):
    body = f"version: test.v1\n{review_block}biomarkers:\n{markers}"
    path = tmp_path / "catalog.yaml"
    path.write_text(body)
    monkeypatch.setattr(catalog, "CATALOG_PATH", path)
    _clear()
    return path


# ── The fingerprint ──────────────────────────────────────────────────────────

def test_a_marker_has_a_stable_fingerprint(tmp_path, monkeypatch):
    write_catalog(tmp_path, monkeypatch, UNREVIEWED)

    assert marker_fingerprint("hba1c") == marker_fingerprint("hba1c")
    assert len(marker_fingerprint("hba1c")) == 64


def test_two_markers_have_different_fingerprints(tmp_path, monkeypatch):
    write_catalog(tmp_path, monkeypatch, UNREVIEWED, HBA1C + FERRITIN)

    assert marker_fingerprint("hba1c") != marker_fingerprint("ferritin")


def test_changing_a_range_changes_the_fingerprint(tmp_path, monkeypatch):
    write_catalog(tmp_path, monkeypatch, UNREVIEWED)
    before = marker_fingerprint("hba1c")

    write_catalog(tmp_path, monkeypatch, UNREVIEWED,
                  HBA1C.replace("optimal: [4.8, 5.2]", "optimal: [4.8, 5.4]"))

    assert marker_fingerprint("hba1c") != before


def test_changing_a_unit_conversion_changes_the_fingerprint(tmp_path, monkeypatch):
    """A wrong conversion factor shifts every value for that marker while
    leaving the ranges looking untouched. It is exactly the kind of edit that
    must not inherit a signature."""
    write_catalog(tmp_path, monkeypatch, UNREVIEWED)
    before = marker_fingerprint("hba1c")

    write_catalog(tmp_path, monkeypatch, UNREVIEWED,
                  HBA1C.replace('"%": 1.0', '"%": 1.0\n    "mmol/mol": 0.0915'))

    assert marker_fingerprint("hba1c") != before


def test_changing_the_citation_changes_the_fingerprint(tmp_path, monkeypatch):
    write_catalog(tmp_path, monkeypatch, UNREVIEWED)
    before = marker_fingerprint("hba1c")

    write_catalog(tmp_path, monkeypatch, UNREVIEWED,
                  HBA1C.replace("ADA Standards of Care", "Something else entirely"))

    assert marker_fingerprint("hba1c") != before


def test_an_unknown_marker_has_no_fingerprint(tmp_path, monkeypatch):
    write_catalog(tmp_path, monkeypatch, UNREVIEWED)

    assert marker_fingerprint("midichlorian_count") is None


# ── Per-marker sign-off ──────────────────────────────────────────────────────

def test_a_marker_can_be_signed_off_on_its_own(tmp_path, monkeypatch):
    write_catalog(tmp_path, monkeypatch, UNREVIEWED, HBA1C + FERRITIN)
    hba1c = marker_fingerprint("hba1c")
    write_catalog(tmp_path, monkeypatch, signed_markers(("hba1c", hba1c)),
                  HBA1C + FERRITIN)

    assert catalog.review_status("hba1c").reviewed is True
    assert catalog.review_status("ferritin").reviewed is False


def test_the_whole_catalog_is_still_unreviewed(tmp_path, monkeypatch):
    """One marker signed off does not make the file reviewed. Anything asking
    the blunt question must still get the blunt answer."""
    write_catalog(tmp_path, monkeypatch, UNREVIEWED, HBA1C)
    write_catalog(tmp_path, monkeypatch,
                  signed_markers(("hba1c", marker_fingerprint("hba1c"))), HBA1C)

    assert catalog.review_status().reviewed is False


def test_a_signed_off_marker_grades_normally(tmp_path, monkeypatch):
    write_catalog(tmp_path, monkeypatch, UNREVIEWED, HBA1C)
    write_catalog(tmp_path, monkeypatch,
                  signed_markers(("hba1c", marker_fingerprint("hba1c"))), HBA1C)
    resolved = RangeResolver().resolve("hba1c", user_id="u1")

    assert grade_for_display(5.0, resolved) == OPTIMAL


def test_an_unsigned_marker_is_still_ungraded(tmp_path, monkeypatch):
    write_catalog(tmp_path, monkeypatch, UNREVIEWED, HBA1C + FERRITIN)
    write_catalog(tmp_path, monkeypatch,
                  signed_markers(("hba1c", marker_fingerprint("hba1c"))),
                  HBA1C + FERRITIN)
    resolved = RangeResolver().resolve("ferritin", user_id="u1")

    assert grade_for_display(100.0, resolved) == UNGRADED


# ── The hash is what makes the signature mean something ──────────────────────

def test_editing_a_range_after_sign_off_withdraws_the_sign_off(tmp_path, monkeypatch):
    """The whole point. A clinician signed off 4.8–5.2; somebody widened it to
    5.4; the signature is over the old numbers and must stop counting — in the
    same commit as the edit, without anybody remembering to revoke it."""
    write_catalog(tmp_path, monkeypatch, UNREVIEWED, HBA1C)
    signed = signed_markers(("hba1c", marker_fingerprint("hba1c")))
    write_catalog(tmp_path, monkeypatch, signed, HBA1C)
    assert catalog.review_status("hba1c").reviewed is True

    write_catalog(tmp_path, monkeypatch, signed,
                  HBA1C.replace("optimal: [4.8, 5.2]", "optimal: [4.8, 5.4]"))

    assert catalog.review_status("hba1c").reviewed is False


def test_a_sign_off_over_the_wrong_hash_never_counted(tmp_path, monkeypatch):
    write_catalog(tmp_path, monkeypatch, signed_markers(("hba1c", "0" * 64)), HBA1C)

    assert catalog.review_status("hba1c").reviewed is False


def test_a_sign_off_must_carry_a_hash(tmp_path, monkeypatch):
    """Without one it is a signature over a name, which is worth nothing. The
    loader refuses it rather than treating it as a sign-off."""
    with pytest.raises(CatalogError, match="content_sha256"):
        write_catalog(tmp_path, monkeypatch, """clinical_review:
  reviewed: false
  markers:
    - id: hba1c
      reviewer: "Dr A. Example"
      reviewed_at: "2026-10-09"
""", HBA1C)
        catalog.marker_reviews()


def test_a_sign_off_must_name_a_reviewer(tmp_path, monkeypatch):
    """Same rule the catalog-level block already enforces, for the same reason:
    without a name there is no audit trail, which is the entire point of
    keeping medical content in git."""
    with pytest.raises(CatalogError, match="reviewer"):
        write_catalog(tmp_path, monkeypatch, """clinical_review:
  reviewed: false
  markers:
    - id: hba1c
      reviewed_at: "2026-10-09"
      content_sha256: "%s"
""" % ("0" * 64), HBA1C)
        catalog.marker_reviews()


def test_a_sign_off_must_carry_a_date(tmp_path, monkeypatch):
    with pytest.raises(CatalogError, match="reviewed_at"):
        write_catalog(tmp_path, monkeypatch, """clinical_review:
  reviewed: false
  markers:
    - id: hba1c
      reviewer: "Dr A. Example"
      content_sha256: "%s"
""" % ("0" * 64), HBA1C)
        catalog.marker_reviews()


def test_a_sign_off_for_a_marker_that_does_not_exist_is_refused(tmp_path, monkeypatch):
    """A sign-off left behind after a marker was removed or renamed. Silently
    ignoring it would mean a reviewer's name sits in the file against nothing."""
    with pytest.raises(CatalogError, match="midichlorian_count"):
        write_catalog(
            tmp_path, monkeypatch,
            signed_markers(("midichlorian_count", "0" * 64)), HBA1C,
        )
        catalog.marker_reviews()


# ── The catalog-level block still means what it meant ────────────────────────

def test_a_fully_reviewed_catalog_covers_every_marker(tmp_path, monkeypatch):
    """Today's behaviour, unchanged. `reviewed: true` at the top still means all
    of it, and does not require a per-marker entry for each one."""
    write_catalog(tmp_path, monkeypatch, FULLY_REVIEWED, HBA1C + FERRITIN)

    assert catalog.review_status().reviewed is True
    assert catalog.review_status("hba1c").reviewed is True
    assert catalog.review_status("ferritin").reviewed is True


def test_the_shipped_catalog_is_not_reviewed_at_all():
    """If this ever fails, somebody has opened the gate. That should be a pull
    request with a clinician's name on it, not a surprise in CI."""
    assert catalog.review_status().reviewed is False
    assert catalog.marker_reviews() == {}


# ── What this unblocks ───────────────────────────────────────────────────────
#
# F4 left biological age computed, stored, rendered, agent-readable and
# withheld: `biological_age_for_display` returns no number and writes none
# while the catalog is unreviewed, so nothing leaks through the select policy on
# score_snapshots. The handoff calls flipping that "F5's business".
#
# The gate now asks the right question. A biological age is a function of nine
# specific markers, so what it needs is those nine signed off -- not a view on
# cortisol, which contributes nothing to it.

import yaml as _yaml

from app.analytics.biological_age import (
    CLINICAL_REVIEW,
    PHENOAGE_MARKERS,
    biological_age_for_display,
)
from app.analytics.subject import Subject

#: A complete, physiologically ordinary panel in canonical units.
HEALTHY_PANEL = {
    "albumin": 4.4,
    "creatinine": 0.9,
    "glucose_fasting": 92.0,
    "hs_crp": 0.8,
    "lymphocyte_percent": 32.0,
    "mcv": 89.0,
    "rdw": 13.0,
    "alkaline_phosphatase": 70.0,
    "wbc": 6.0,
}


def real_catalog_signed(tmp_path, monkeypatch, marker_ids):
    """The shipped catalog with `marker_ids` signed off, hashes computed from it.

    Deliberately the real file rather than a fixture: the nine PhenoAge markers
    and their ranges are the thing being signed off, and a hand-written stand-in
    would pass while the real catalog was missing a marker.
    """
    raw = _yaml.safe_load(catalog.CATALOG_PATH.read_text())

    # Fingerprints have to come from the catalog as loaded, so point at a copy
    # first and read them back.
    plain = tmp_path / "plain.yaml"
    plain.write_text(_yaml.safe_dump(raw, sort_keys=False))
    monkeypatch.setattr(catalog, "CATALOG_PATH", plain)
    _clear()
    signed = [
        {
            "id": marker_id,
            "reviewer": "Dr A. Example, MBBS MD, reg. 12345",
            "reviewed_at": "2026-10-09",
            "content_sha256": catalog.marker_fingerprint(marker_id),
        }
        for marker_id in marker_ids
    ]

    raw["clinical_review"] = {"reviewed": False, "markers": signed}
    path = tmp_path / "signed.yaml"
    path.write_text(_yaml.safe_dump(raw, sort_keys=False))
    monkeypatch.setattr(catalog, "CATALOG_PATH", path)
    _clear()
    return path


def test_the_shipped_catalog_withholds_a_biological_age():
    """Today, and until a clinician signs. This is F4's deliberate withholding
    and it must stay true until somebody's name is in the file."""
    result = biological_age_for_display(
        HEALTHY_PANEL, Subject(age_years=44.0, sex="male")
    )

    assert result.score is None
    assert CLINICAL_REVIEW in result.missing_inputs
    assert result.drivers == []


def test_signing_off_the_nine_phenoage_markers_releases_the_number(
    tmp_path, monkeypatch
):
    """The unblock, and the smallest sign-off that achieves it: nine markers of
    thirty-three."""
    real_catalog_signed(tmp_path, monkeypatch, PHENOAGE_MARKERS)

    result = biological_age_for_display(
        HEALTHY_PANEL, Subject(age_years=44.0, sex="male")
    )

    assert result.score is not None
    assert CLINICAL_REVIEW not in result.missing_inputs
    assert result.drivers


def test_eight_of_the_nine_is_not_enough(tmp_path, monkeypatch):
    """The number is a function of all nine. A sign-off covering eight of them
    is a sign-off of something else, and publishing the drivers while
    withholding the total would hand over the same claim in instalments."""
    real_catalog_signed(tmp_path, monkeypatch, PHENOAGE_MARKERS[:-1])

    result = biological_age_for_display(
        HEALTHY_PANEL, Subject(age_years=44.0, sex="male")
    )

    assert result.score is None
    assert CLINICAL_REVIEW in result.missing_inputs
    assert result.drivers == []


def test_signing_off_an_unrelated_marker_releases_nothing(tmp_path, monkeypatch):
    """Cortisol contributes nothing to PhenoAge. Signing it off must not move
    the biological-age gate at all."""
    real_catalog_signed(tmp_path, monkeypatch, ["cortisol_morning"])

    assert biological_age_for_display(
        HEALTHY_PANEL, Subject(age_years=44.0, sex="male")
    ).score is None


def test_editing_a_phenoage_range_after_sign_off_withholds_the_number_again(
    tmp_path, monkeypatch
):
    """The hash doing its job on the claim that matters most. Someone widens
    RDW's optimal band after the sign-off; the signature is over the old
    numbers; the biological age goes back to being withheld, in the same commit
    as the edit."""
    path = real_catalog_signed(tmp_path, monkeypatch, PHENOAGE_MARKERS)
    assert biological_age_for_display(
        HEALTHY_PANEL, Subject(age_years=44.0, sex="male")
    ).score is not None

    raw = _yaml.safe_load(path.read_text())
    for entry in raw["biomarkers"]:
        if entry["id"] == "rdw":
            entry["optimal"] = [11.5, 14.5]
    path.write_text(_yaml.safe_dump(raw, sort_keys=False))
    _clear()

    result = biological_age_for_display(
        HEALTHY_PANEL, Subject(age_years=44.0, sex="male")
    )
    assert result.score is None
    assert CLINICAL_REVIEW in result.missing_inputs
