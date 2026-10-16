"""The operational therapy catalogue is useful even without an effect claim."""

import yaml
import pytest

from app.analytics import therapy_catalog
from app.analytics.therapy_catalog import TherapyCatalogError
from app.migrate.therapy_catalogue_seed import catalogue_seed_rows, publish_catalogue


def test_shipped_catalogue_has_the_f12_operational_depth():
    _, modalities = therapy_catalog.load_modalities()

    assert len(modalities) >= 25
    assert {
        "cryotherapy", "hbot", "mild_hbot", "sauna", "infrared_sauna",
        "cold_plunge", "contrast_therapy", "red_light", "pemf",
        "hydrogen_inhalation", "ihht", "ewot", "compression",
        "vibroacoustic", "float_therapy", "iv_vitamin_c",
    } <= set(modalities)


def test_deployment_publishes_the_exact_operational_catalogue():
    class Cursor:
        def __init__(self):
            self.calls = []

        def execute(self, sql, params=None):
            self.calls.append((sql, params))

    cursor = Cursor()
    rows = catalogue_seed_rows()

    assert len(rows) == 25
    assert {row["slug"] for row in rows} == set(therapy_catalog.load_modalities()[1])
    assert publish_catalogue(cursor) == 25
    upserts = [call for call in cursor.calls if "insert into therapy_catalogue" in call[0]]
    assert len(upserts) == 25
    assert {params["slug"] for _, params in upserts} == set(therapy_catalog.load_modalities()[1])


def test_every_modality_has_complete_operational_metadata():
    _, modalities = therapy_catalog.load_modalities()

    event_types = []
    for modality in modalities.values():
        assert modality.label
        assert modality.category
        assert modality.summary
        assert modality.intended_experience
        assert modality.dose_schema
        assert isinstance(modality.contraindication_rule_ids, tuple)
        event_types.extend(modality.event_types)

    assert len(event_types) == len(set(event_types))


def test_a_modality_needs_no_speculative_wearable_effect(tmp_path):
    path = tmp_path / "catalogue.yaml"
    path.write_text(yaml.safe_dump({
        "version": "test",
        "modalities": [{
            "id": "float_therapy",
            "label": "Float therapy",
            "category": "recovery",
            "summary": "A quiet supported float session.",
            "intended_experience": "Reduced external stimulation.",
            "event_types": ["float_therapy"],
            "dose_schema": {"duration_minutes": {"minimum": 1}},
            "contraindication_rule_ids": [],
            "effects": [],
        }],
        "clinical_review": {"effects": []},
    }))
    therapy_catalog.load_modalities.cache_clear()

    _, modalities = therapy_catalog.load_modalities(path)

    assert modalities["float_therapy"].effects == ()
    therapy_catalog.load_modalities.cache_clear()


@pytest.mark.parametrize("missing", [
    "category", "summary", "intended_experience", "dose_schema",
    "contraindication_rule_ids",
])
def test_incomplete_operational_metadata_fails_closed(tmp_path, missing):
    entry = {
        "id": "sauna",
        "label": "Sauna",
        "category": "heat",
        "summary": "A controlled heat session.",
        "intended_experience": "Warm supervised exposure.",
        "event_types": ["sauna"],
        "dose_schema": {"duration_minutes": {"minimum": 1}},
        "contraindication_rule_ids": ["alcohol_today"],
        "effects": [],
    }
    entry.pop(missing)
    path = tmp_path / "catalogue.yaml"
    path.write_text(yaml.safe_dump({
        "version": "test", "modalities": [entry],
        "clinical_review": {"effects": []},
    }))
    therapy_catalog.load_modalities.cache_clear()

    with pytest.raises(TherapyCatalogError, match=missing):
        therapy_catalog.load_modalities(path)

    therapy_catalog.load_modalities.cache_clear()


def test_one_event_type_cannot_mean_two_modalities(tmp_path):
    base = {
        "label": "Test",
        "category": "recovery",
        "summary": "A test session.",
        "intended_experience": "A test experience.",
        "event_types": ["same_event"],
        "dose_schema": {"duration_minutes": {"minimum": 1}},
        "contraindication_rule_ids": [],
        "effects": [],
    }
    path = tmp_path / "catalogue.yaml"
    path.write_text(yaml.safe_dump({
        "version": "test",
        "modalities": [dict(base, id="one"), dict(base, id="two")],
        "clinical_review": {"effects": []},
    }))
    therapy_catalog.load_modalities.cache_clear()

    with pytest.raises(TherapyCatalogError, match="event type"):
        therapy_catalog.load_modalities(path)

    therapy_catalog.load_modalities.cache_clear()
