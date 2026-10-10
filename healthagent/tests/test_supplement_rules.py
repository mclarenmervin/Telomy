"""The supplement rule file, and the sign-off that makes one usable.

A reference range says what a number means. A supplement rule says what to do
about it, which is a different and much stronger claim — so it is a separate
file, with its own sign-off, signed by its own professional act. A clinician
who agreed that vitamin D's reference interval is 30–100 ng/mL has not thereby
agreed that a level below it should be supplemented, and binding the two to one
signature would mean exactly that.

Everything else follows `biomarkers.v1.yaml`'s discipline, for the same
reasons: medical content in git so changes get diffs and blame, loud validation
at load time, and a per-rule signature bound to a hash of what was signed, so
editing the rule afterwards withdraws the sign-off instead of inheriting it.
"""

import pytest

from app.analytics import catalog, supplement_rules
from app.analytics.supplement_rules import (
    BELOW_STANDARD,
    SupplementRuleError,
    load_rules,
    review_status,
    rule_fingerprint,
    rules_for,
)


@pytest.fixture(autouse=True)
def _clear_caches():
    _clear()
    yield
    _clear()


def _clear():
    for cache in (load_rules, review_status, rules_for, catalog.load_catalog):
        cache.cache_clear()


VITAMIN_D = """  - id: vitamin_d_repletion
    biomarker: vitamin_d_25oh
    supplement: "Vitamin D3 (cholecalciferol)"
    trigger: below_standard
    recommendation: "Vitamin D supplementation is the usual response to a level this low."
    citation: "Holick MF et al. PMID 21646368"
"""

FERRITIN = """  - id: iron_repletion
    biomarker: ferritin
    supplement: "Oral iron"
    trigger: below_standard
    recommendation: "Iron supplementation is the usual response once the cause has been considered."
    citation: "WHO ferritin guidance (2020)"
"""

UNREVIEWED = """clinical_review:
  reviewed: false
  reviewer:
  reviewed_at:
"""


def signed_rules(*entries) -> str:
    rows = "".join(
        f'''    - id: {rule_id}
      reviewer: "Dr A. Example, MBBS MD, reg. 12345"
      reviewed_at: "2026-10-10"
      content_sha256: "{fingerprint}"
'''
        for rule_id, fingerprint in entries
    )
    return f"""clinical_review:
  reviewed: false
  reviewer:
  reviewed_at:
  rules:
{rows}"""


def write_rules(tmp_path, monkeypatch, review_block: str, rules: str = VITAMIN_D):
    path = tmp_path / "supplements.yaml"
    path.write_text(f"version: test.v1\n{review_block}rules:\n{rules}")
    monkeypatch.setattr(supplement_rules, "RULES_PATH", path)
    _clear()
    return path


# ── The shipped file ─────────────────────────────────────────────────────────

def test_the_shipped_rules_load():
    version, rules = load_rules()

    assert version == "supplements.v1"
    assert rules


def test_every_rule_names_a_marker_the_catalog_has():
    """A rule for a marker the catalog does not carry can never fire, and would
    be invisible: the queue would simply stay empty."""
    for rule in load_rules()[1].values():
        assert catalog.get(rule.biomarker_id) is not None, rule.id


def test_every_rule_carries_a_citation_and_a_recommendation():
    for rule in load_rules()[1].values():
        assert rule.citation.strip(), rule.id
        assert rule.recommendation.strip(), rule.id


def test_nothing_is_signed_off_yet():
    """The shipped state, deliberately. A signature needs a real clinician's
    name, registration and date, and until then no supplement draft can be
    produced at all."""
    for rule_id in load_rules()[1]:
        assert review_status(rule_id).reviewed is False, rule_id


def test_every_shipped_rule_is_a_deficiency_rule():
    """Repletion of a measured deficiency is the defensible claim. Recommending
    a supplement for a value inside the reference range is optimisation, which
    rests on a far weaker evidence base and is not what this phase ships."""
    for rule in load_rules()[1].values():
        assert rule.trigger == BELOW_STANDARD, rule.id


# ── Validation, loudly and at load time ──────────────────────────────────────

def test_a_rule_for_an_unknown_marker_is_refused(tmp_path, monkeypatch):
    with pytest.raises(SupplementRuleError, match="midichlorian_count"):
        write_rules(
            tmp_path,
            monkeypatch,
            UNREVIEWED,
            VITAMIN_D.replace("vitamin_d_25oh", "midichlorian_count"),
        )
        load_rules()


def test_a_rule_with_no_citation_is_refused(tmp_path, monkeypatch):
    with pytest.raises(SupplementRuleError, match="citation"):
        write_rules(
            tmp_path,
            monkeypatch,
            UNREVIEWED,
            VITAMIN_D.replace('    citation: "Holick MF et al. PMID 21646368"\n', ""),
        )
        load_rules()


def test_a_rule_with_no_recommendation_is_refused(tmp_path, monkeypatch):
    body = "\n".join(
        line for line in VITAMIN_D.splitlines() if "recommendation:" not in line
    )
    with pytest.raises(SupplementRuleError, match="recommendation"):
        write_rules(tmp_path, monkeypatch, UNREVIEWED, body + "\n")
        load_rules()


def test_an_unknown_trigger_is_refused(tmp_path, monkeypatch):
    """`below_optimal` is the one a future phase would add, and adding it is a
    clinical decision rather than a typo somebody can make in passing."""
    with pytest.raises(SupplementRuleError, match="trigger"):
        write_rules(
            tmp_path,
            monkeypatch,
            UNREVIEWED,
            VITAMIN_D.replace("below_standard", "below_optimal"),
        )
        load_rules()


def test_a_duplicate_rule_id_is_refused(tmp_path, monkeypatch):
    with pytest.raises(SupplementRuleError, match="twice"):
        write_rules(tmp_path, monkeypatch, UNREVIEWED, VITAMIN_D + VITAMIN_D)
        load_rules()


def test_an_interaction_without_a_note_is_refused(tmp_path, monkeypatch):
    """The note is what the draft prints. An interaction with no explanation
    would route a draft to a human without telling them why."""
    with pytest.raises(SupplementRuleError, match="note"):
        write_rules(
            tmp_path,
            monkeypatch,
            UNREVIEWED,
            VITAMIN_D + "    interactions:\n      - medications: [thiazide]\n",
        )
        load_rules()


def test_an_interaction_with_no_medications_is_refused(tmp_path, monkeypatch):
    with pytest.raises(SupplementRuleError, match="medications"):
        write_rules(
            tmp_path,
            monkeypatch,
            UNREVIEWED,
            VITAMIN_D + '    interactions:\n      - note: "matters"\n',
        )
        load_rules()


def test_a_signoff_for_a_rule_that_does_not_exist_is_refused(tmp_path, monkeypatch):
    """A reviewer's name left in the file against a rule that was renamed reads
    like coverage we do not have."""
    with pytest.raises(SupplementRuleError, match="do not exist"):
        write_rules(tmp_path, monkeypatch, signed_rules(("gone", "0" * 64)))
        load_rules()


def test_a_signoff_with_no_reviewer_is_refused(tmp_path, monkeypatch):
    block = """clinical_review:
  reviewed: false
  rules:
    - id: vitamin_d_repletion
      reviewed_at: "2026-10-10"
      content_sha256: "%s"
""" % ("0" * 64)
    with pytest.raises(SupplementRuleError, match="reviewer"):
        write_rules(tmp_path, monkeypatch, block)
        load_rules()


def test_a_signoff_with_no_hash_is_refused(tmp_path, monkeypatch):
    block = """clinical_review:
  reviewed: false
  rules:
    - id: vitamin_d_repletion
      reviewer: "Dr A. Example"
      reviewed_at: "2026-10-10"
"""
    with pytest.raises(SupplementRuleError, match="content_sha256"):
        write_rules(tmp_path, monkeypatch, block)
        load_rules()


# ── The fingerprint ──────────────────────────────────────────────────────────

def test_a_rule_has_a_stable_fingerprint(tmp_path, monkeypatch):
    write_rules(tmp_path, monkeypatch, UNREVIEWED)

    assert rule_fingerprint("vitamin_d_repletion") == rule_fingerprint(
        "vitamin_d_repletion"
    )
    assert len(rule_fingerprint("vitamin_d_repletion")) == 64


def test_two_rules_have_different_fingerprints(tmp_path, monkeypatch):
    write_rules(tmp_path, monkeypatch, UNREVIEWED, VITAMIN_D + FERRITIN)

    assert rule_fingerprint("vitamin_d_repletion") != rule_fingerprint("iron_repletion")


def test_changing_the_recommendation_changes_the_fingerprint(tmp_path, monkeypatch):
    """The recommendation is the sentence the draft prints and the clinician
    signs. Editing it after a sign-off must not inherit the signature."""
    write_rules(tmp_path, monkeypatch, UNREVIEWED)
    before = rule_fingerprint("vitamin_d_repletion")

    write_rules(
        tmp_path,
        monkeypatch,
        UNREVIEWED,
        VITAMIN_D.replace("the usual response", "always the right answer"),
    )

    assert rule_fingerprint("vitamin_d_repletion") != before


def test_changing_the_citation_changes_the_fingerprint(tmp_path, monkeypatch):
    write_rules(tmp_path, monkeypatch, UNREVIEWED)
    before = rule_fingerprint("vitamin_d_repletion")

    write_rules(
        tmp_path,
        monkeypatch,
        UNREVIEWED,
        VITAMIN_D.replace("PMID 21646368", "PMID 99999999"),
    )

    assert rule_fingerprint("vitamin_d_repletion") != before


def test_an_unknown_rule_has_no_fingerprint(tmp_path, monkeypatch):
    write_rules(tmp_path, monkeypatch, UNREVIEWED)

    assert rule_fingerprint("nonsense") is None


# ── Per-rule sign-off ────────────────────────────────────────────────────────

def test_a_rule_can_be_signed_off_on_its_own(tmp_path, monkeypatch):
    write_rules(tmp_path, monkeypatch, UNREVIEWED, VITAMIN_D + FERRITIN)
    signed = signed_rules(("vitamin_d_repletion", rule_fingerprint("vitamin_d_repletion")))
    write_rules(tmp_path, monkeypatch, signed, VITAMIN_D + FERRITIN)

    assert review_status("vitamin_d_repletion").reviewed is True
    assert review_status("iron_repletion").reviewed is False


def test_a_signoff_names_the_clinician_who_made_it(tmp_path, monkeypatch):
    write_rules(tmp_path, monkeypatch, UNREVIEWED)
    signed = signed_rules(("vitamin_d_repletion", rule_fingerprint("vitamin_d_repletion")))
    write_rules(tmp_path, monkeypatch, signed)

    status = review_status("vitamin_d_repletion")

    assert "Dr A. Example" in status.reviewer
    assert status.reviewed_at == "2026-10-10"


def test_editing_a_signed_rule_withdraws_the_signoff(tmp_path, monkeypatch):
    """The withdrawal, and the whole point of binding the signature to a hash.
    A recommendation can stop being deliverable because somebody edited the
    sentence it rests on, and that is correct."""
    write_rules(tmp_path, monkeypatch, UNREVIEWED)
    signed = signed_rules(("vitamin_d_repletion", rule_fingerprint("vitamin_d_repletion")))
    write_rules(tmp_path, monkeypatch, signed)
    assert review_status("vitamin_d_repletion").reviewed is True

    write_rules(
        tmp_path,
        monkeypatch,
        signed,
        VITAMIN_D.replace("the usual response", "always the right answer"),
    )

    assert review_status("vitamin_d_repletion").reviewed is False


def test_rules_are_looked_up_by_marker(tmp_path, monkeypatch):
    write_rules(tmp_path, monkeypatch, UNREVIEWED, VITAMIN_D + FERRITIN)

    assert [r.id for r in rules_for("ferritin")] == ["iron_repletion"]
    assert rules_for("hba1c") == ()


def test_the_magnesium_rule_knows_about_potassium_sparing_diuretics():
    """The plan's own example of what this phase exists to route to a human: a
    magnesium recommendation for somebody on a potassium-sparing diuretic. It is
    no use having the interaction machinery if the obvious interaction is
    missing from the file."""
    rule = next(r for r in rules_for("magnesium"))
    matched = [
        i for i in rule.interactions if i.matched_in("Spironolactone 25mg daily")
    ]

    assert matched
    assert "hypermagnesaemia" in matched[0].note


def test_an_interaction_matches_a_medication_as_a_person_typed_it():
    """A medication list is free text. "Tab. Metformin 500mg BD" is what is
    actually in the table, not "metformin"."""
    rule = next(r for r in rules_for("vitamin_b12") if r.id == "b12_repletion")
    interaction = next(i for i in rule.interactions if "metformin" in i.medications)

    assert interaction.matched_in("Tab. Metformin 500mg BD") == "metformin"
    assert interaction.matched_in("Vitamin C") is None
