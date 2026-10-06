"""Deciding which biomarker a printed label names.

This is the *only* place an LLM touches lab extraction, and it is asked exactly
one kind of question: "the lab printed `FBS (F)` — which marker is that?" It is
never asked what the value is, never asked to convert anything, and never shown
a number it could return.

Two tiers, deterministic first. Most Indian panels print predictable labels, so
the catalog's own alias table answers the majority without a model call at all —
cheaper, instant, reviewable in a pull request, and not subject to a bad
generation. The model only ever sees what the alias table could not place.

The guarantee that matters is structural rather than behavioural: the mapper
takes label *strings*. There is no parameter through which a value could reach
it, so no prompt it builds can contain one.
"""

import json

import pytest

from app.analytics import catalog
from app.extraction.mapping import (
    ALIAS,
    LLM,
    UNMAPPED,
    map_unit,
    resolve_labels,
)
from app.extraction.pdf_text import read_pdf
from app.extraction.scan import scan_page
from tests.lab_fixtures import lab_report_pdf


class SpyLLM:
    """Records everything it is shown, and answers from a fixed script."""

    def __init__(self, answer=None):
        self._answer = answer if answer is not None else {}
        self.seen: list[str] = []
        self.calls = 0

    def invoke(self, messages):
        self.calls += 1
        self.seen.append(" ".join(str(part) for pair in messages for part in pair))

        class Response:
            content = json.dumps(self._answer)

        return Response()


# ── The deterministic tier ───────────────────────────────────────────────────

def test_a_known_label_maps_without_calling_the_model():
    spy = SpyLLM()

    mapped = resolve_labels(["Glucose, Fasting"], llm=spy)

    assert mapped["Glucose, Fasting"].biomarker_id == "glucose_fasting"
    assert mapped["Glucose, Fasting"].source == ALIAS
    assert spy.calls == 0, "the alias table answered; no model call should happen"


@pytest.mark.parametrize("printed", [
    "HbA1c",
    "HBA1C",
    "Hb A1c",
    "Glycosylated Haemoglobin (HbA1c)",
])
def test_labels_match_across_the_spellings_labs_actually_print(printed):
    assert resolve_labels([printed])[printed].biomarker_id == "hba1c"


def test_a_whole_panel_maps_from_the_alias_table_alone():
    document = read_pdf(lab_report_pdf())
    labels = [c.label for c in scan_page(document.pages[0])]
    spy = SpyLLM()

    mapped = resolve_labels(labels, llm=spy)

    assert mapped["Glucose, Fasting"].biomarker_id == "glucose_fasting"
    assert mapped["HbA1c"].biomarker_id == "hba1c"
    assert mapped["Haemoglobin"].biomarker_id == "haemoglobin"
    assert mapped["Vitamin D, 25 - Hydroxy"].biomarker_id == "vitamin_d_25oh"
    assert mapped["Ferritin"].biomarker_id == "ferritin"
    # The model is asked once, about Dengue NS1, which we do not carry. Every
    # marker we do carry was placed by the table without a model call.
    ours = [label for label in mapped if "Dengue" not in label]
    assert all(mapped[label].source == ALIAS for label in ours)


def test_a_marker_outside_our_catalog_stays_unmapped():
    """Dengue NS1 is on the fixture panel and is not one of our 31 markers. The
    failure to avoid is not missing it — it is filing it under something we do
    carry because the label looked vaguely similar."""
    mapped = resolve_labels(["Dengue NS1 Antigen"], llm=None)

    assert mapped["Dengue NS1 Antigen"].biomarker_id is None


def test_the_same_analyte_in_a_different_context_keeps_the_context():
    """Fasting and post-prandial glucose are one marker and two results. The
    context is what separates them in the uniqueness key, and it is also what
    stops a post-prandial value being graded against fasting ranges."""
    mapped = resolve_labels(["Glucose, Post Prandial"], llm=None)

    assert mapped["Glucose, Post Prandial"].biomarker_id == "glucose_fasting"
    assert mapped["Glucose, Post Prandial"].context == "post_prandial"


def test_an_ordinary_label_carries_the_standard_context():
    assert resolve_labels(["Ferritin"])["Ferritin"].context == "standard"


# ── The model never sees a value ─────────────────────────────────────────────

def test_the_model_is_never_shown_a_number_from_the_report():
    """P2, as a test rather than a convention.

    The panel is scanned for real, then only its labels are handed over. If any
    value reached the prompt, the model would have something to 'correct'.
    """
    document = read_pdf(lab_report_pdf())
    candidates = scan_page(document.pages[0])
    spy = SpyLLM()

    resolve_labels([c.label for c in candidates] + ["Mystery Analyte X"], llm=spy)

    prompt = " ".join(spy.seen)
    for candidate in candidates:
        assert candidate.value_text not in prompt, (
            f"the value {candidate.value_text!r} reached the model"
        )


def test_the_model_is_only_asked_about_labels_the_table_could_not_place():
    spy = SpyLLM({"Mystery Analyte X": "ferritin"})

    resolve_labels(["Glucose, Fasting", "HbA1c", "Mystery Analyte X"], llm=spy)

    prompt = " ".join(spy.seen)
    assert "Mystery Analyte X" in prompt
    assert "Glucose, Fasting" not in prompt


# ── What comes back from the model is not trusted ────────────────────────────

def test_a_model_answer_naming_a_marker_we_do_not_have_is_discarded():
    """A hallucinated id would otherwise become a row keyed to a marker with no
    ranges, no units and no citation."""
    spy = SpyLLM({"Mystery Analyte X": "midichlorian_count"})

    mapped = resolve_labels(["Mystery Analyte X"], llm=spy)

    assert mapped["Mystery Analyte X"].biomarker_id is None
    assert mapped["Mystery Analyte X"].source == UNMAPPED


def test_a_model_answer_about_a_label_we_did_not_ask_about_is_ignored():
    spy = SpyLLM({"Something Else Entirely": "ferritin"})

    mapped = resolve_labels(["Mystery Analyte X"], llm=spy)

    assert "Something Else Entirely" not in mapped
    assert mapped["Mystery Analyte X"].biomarker_id is None


def test_extra_fields_in_the_model_answer_cannot_carry_a_value():
    """Even if a model tried to volunteer one, there is nowhere for it to go:
    the answer is read as {label: biomarker_id} and nothing else is consulted."""
    spy = SpyLLM({"Mystery Analyte X": "ferritin", "value": "999", "unit": "mg/dL"})

    mapped = resolve_labels(["Mystery Analyte X"], llm=spy)

    assert mapped["Mystery Analyte X"].biomarker_id == "ferritin"
    assert not hasattr(mapped["Mystery Analyte X"], "value")


def test_a_valid_model_answer_is_marked_as_coming_from_the_model():
    """Provenance, because an alias match and a model guess do not deserve the
    same confidence at confirmation time."""
    spy = SpyLLM({"Mystery Analyte X": "ferritin"})

    mapped = resolve_labels(["Mystery Analyte X"], llm=spy)

    assert mapped["Mystery Analyte X"].source == LLM
    assert mapped["Mystery Analyte X"].confidence < 1.0


def test_unparseable_model_output_leaves_the_label_unmapped():
    class Broken:
        def invoke(self, messages):
            class Response:
                content = "I'm afraid I can't help with that."

            return Response()

    mapped = resolve_labels(["Mystery Analyte X"], llm=Broken())

    assert mapped["Mystery Analyte X"].biomarker_id is None


# ── Without a model at all ───────────────────────────────────────────────────

def test_an_unknown_label_is_unmapped_rather_than_guessed():
    mapped = resolve_labels(["Mystery Analyte X"], llm=None)

    assert mapped["Mystery Analyte X"].biomarker_id is None
    assert mapped["Mystery Analyte X"].source == UNMAPPED


def test_extraction_works_with_no_model_configured():
    """The alias table is the product, not a cache in front of the model. With
    no LLM at all, every marker we carry still comes through."""
    document = read_pdf(lab_report_pdf())
    labels = [c.label for c in scan_page(document.pages[0])]

    mapped = resolve_labels(labels, llm=None)

    ours = [m for label, m in mapped.items() if "Dengue" not in label]
    assert all(m.biomarker_id for m in ours)


# ── Units ────────────────────────────────────────────────────────────────────

def test_a_unit_the_catalog_knows_is_accepted():
    assert map_unit("glucose_fasting", "mg/dL") == "mg/dL"


def test_unit_spelling_variants_resolve():
    assert map_unit("glucose_fasting", "mgs/dl") == "mg/dL"
    assert map_unit("ferritin", "ng/ml") == "ng/mL"


def test_a_unit_the_catalog_cannot_convert_is_refused_not_guessed():
    """A wrong conversion is indistinguishable from a real abnormal result once
    it is a number on a chart."""
    assert map_unit("glucose_fasting", "furlongs per fortnight") is None


def test_a_missing_unit_is_not_invented():
    assert map_unit("glucose_fasting", None) is None
    assert map_unit("glucose_fasting", "") is None


# ── The alias table itself ───────────────────────────────────────────────────

def test_no_alias_is_claimed_by_two_markers():
    """An alias on two markers would make the mapping order-dependent, and the
    loser would be silently misfiled rather than refused."""
    index = catalog.alias_index()

    assert len(index) == len(set(index))


def test_every_marker_can_be_reached_by_at_least_one_alias():
    _, markers = catalog.load_catalog()
    reachable = set(catalog.alias_index().values())

    assert set(markers) - reachable == set()
