"""The catalog is medical content, so its coherence is a test, not a convention.

The failure this guards against is the worst kind available here: a transposed
digit in a range nobody reads closely, which silently poisons biological age and
supplement recommendations without ever looking like a bug.
"""

import textwrap

import pytest

from app.analytics import catalog
from app.analytics.catalog import CatalogError, load_catalog


def write_catalog(tmp_path, body: str):
    path = tmp_path / "test_catalog.yaml"
    path.write_text(textwrap.dedent(body))
    load_catalog.cache_clear()
    return path


GOOD = """
    version: test.v1
    biomarkers:
      - id: glucose_fasting
        name: Fasting glucose
        system: metabolic
        canonical_unit: mg/dL
        units:
          mg/dL: 1.0
          mmol/L: 18.0182
        standard: [70, 99]
        optimal: [70, 85]
        critical: [40, 400]
        citation: "Tirosh A et al. (2011) PMID 21220444"
    """


@pytest.fixture(autouse=True)
def _clear_cache():
    load_catalog.cache_clear()
    yield
    load_catalog.cache_clear()


# ── The shipped catalog ──────────────────────────────────────────────────────

def test_the_shipped_catalog_loads_and_is_coherent():
    version, markers = load_catalog()

    assert version == "global.v1"
    assert len(markers) >= 30


def test_every_shipped_marker_carries_a_citation():
    """A range we cannot cite is a range we cannot defend to a clinician."""
    _, markers = load_catalog()

    assert [m.id for m in markers.values() if not m.citation.strip()] == []


def test_every_shipped_marker_can_convert_its_own_canonical_unit():
    from app.analytics.units import normalise_unit_label

    _, markers = load_catalog()

    for marker in markers.values():
        assert normalise_unit_label(marker.canonical_unit) in marker.conversions


def test_shipped_optimal_ranges_sit_inside_standard_and_standard_inside_critical():
    _, markers = load_catalog()

    for marker in markers.values():
        bands = (
            [(b["standard"], b["optimal"]) for b in marker.by_sex.values()]
            if marker.sex_specific
            else [(marker.standard, marker.optimal)]
        )
        for standard, optimal in bands:
            assert marker.critical.low <= standard.low, marker.id
            assert standard.high <= marker.critical.high, marker.id
            assert standard.low <= optimal.low, marker.id
            assert optimal.high <= standard.high, marker.id


# ── The validator itself ─────────────────────────────────────────────────────

def test_a_missing_citation_is_refused(tmp_path):
    path = write_catalog(tmp_path, GOOD.replace('citation: "Tirosh A et al. (2011) PMID 21220444"', 'citation: ""'))

    with pytest.raises(CatalogError, match="citation"):
        load_catalog(path)


def test_an_optimal_range_outside_standard_is_refused(tmp_path):
    """The transposed-digit case."""
    path = write_catalog(tmp_path, GOOD.replace("optimal: [70, 85]", "optimal: [70, 950]"))

    with pytest.raises(CatalogError, match="optimal"):
        load_catalog(path)


def test_a_standard_range_outside_critical_is_refused(tmp_path):
    path = write_catalog(tmp_path, GOOD.replace("critical: [40, 400]", "critical: [71, 400]"))

    with pytest.raises(CatalogError, match="critical"):
        load_catalog(path)


def test_an_inverted_range_is_refused(tmp_path):
    path = write_catalog(tmp_path, GOOD.replace("standard: [70, 99]", "standard: [99, 70]"))

    with pytest.raises(CatalogError, match="above"):
        load_catalog(path)


def test_a_canonical_unit_absent_from_units_is_refused(tmp_path):
    path = write_catalog(tmp_path, GOOD.replace("canonical_unit: mg/dL", "canonical_unit: pg/mL"))

    with pytest.raises(CatalogError, match="canonical"):
        load_catalog(path)


def test_a_duplicate_marker_is_refused(tmp_path):
    body = GOOD + GOOD.split("biomarkers:")[1]
    path = write_catalog(tmp_path, body)

    with pytest.raises(CatalogError, match="twice"):
        load_catalog(path)


def test_a_sex_specific_marker_missing_a_sex_is_refused(tmp_path):
    path = write_catalog(tmp_path, """
        version: test.v1
        biomarkers:
          - id: ferritin
            name: Ferritin
            system: minerals
            canonical_unit: ng/mL
            units: { ng/mL: 1.0 }
            ranges_by_sex:
              male:
                standard: [30, 400]
                optimal: [70, 200]
            critical: [5, 1500]
            citation: "WHO guidance"
        """)

    with pytest.raises(CatalogError, match="female"):
        load_catalog(path)


# ── Sex handling ─────────────────────────────────────────────────────────────

def test_a_sex_specific_marker_refuses_to_answer_without_a_sex():
    """Picking a default would silently grade a woman against a man's range."""
    _, markers = load_catalog()

    assert markers["ferritin"].ranges_for(None) is None
    assert markers["ferritin"].ranges_for("") is None


def test_a_sex_specific_marker_answers_for_a_known_sex():
    _, markers = load_catalog()

    standard, optimal = markers["ferritin"].ranges_for("female")

    assert standard.low == 15
    assert optimal.high == 150


def test_a_non_sex_specific_marker_answers_regardless():
    _, markers = load_catalog()

    assert markers["hba1c"].ranges_for(None) is not None


def test_get_returns_none_for_an_unknown_marker():
    assert catalog.get("midichlorian_count") is None


# ── PhenoAge completeness ────────────────────────────────────────────────────

# Levine ME et al. (2018), PMID 29676998, Table 1. Nine markers plus
# chronological age. The coefficients are fitted jointly, so a marker that is
# absent from the catalog is not a marker the model can do without -- it is the
# whole model being unavailable.
PHENOAGE_MARKERS = (
    "albumin",
    "creatinine",
    "glucose_fasting",
    "hs_crp",
    "lymphocyte_percent",
    "mcv",
    "alkaline_phosphatase",
    "rdw",
    "wbc",
)


def test_the_catalog_carries_every_phenoage_marker():
    """F4 cannot compute a published biological age without all nine. This test
    is the gate: a marker dropped from the catalog breaks the score loudly here
    rather than quietly producing a number from eight terms."""
    missing = [m for m in PHENOAGE_MARKERS if catalog.get(m) is None]

    assert missing == []
