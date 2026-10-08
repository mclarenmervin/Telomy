"""Who we are scoring, and when we refuse to.

Biological age needs a chronological age to be an age *relative to*, and several
reference ranges need sex. Both may be absent, and one state -- pregnancy --
invalidates the model outright. The plan is explicit that the correct behaviour
is to refuse rather than to score wrongly, so most of these tests are about
refusing.
"""

from datetime import date

from app.analytics.subject import MINIMUM_AGE_YEARS, resolve_subject


def profile(**fields) -> dict:
    base = {"dob": "1980-06-15"}
    base.update(fields)
    return base


AS_OF = date(2026, 6, 15)


# ── Age ──────────────────────────────────────────────────────────────────────

def test_age_is_measured_at_the_collection_date_not_today():
    """A 2019 panel must be scored against the age the person was in 2019.

    Using today's age would make every historical upload look better than it
    was, which is the subtle version of putting a 2023 panel on today's chart.
    """
    subject = resolve_subject(profile(), as_of=date(2019, 6, 15))

    assert round(subject.age_years, 2) == 39.0


def test_age_is_fractional():
    subject = resolve_subject(profile(dob="1980-12-15"), as_of=AS_OF)

    assert 45.4 < subject.age_years < 45.6


def test_a_missing_date_of_birth_refuses_rather_than_assuming_one():
    subject = resolve_subject({"sex": "female"}, as_of=AS_OF)

    assert subject.age_years is None
    assert "date_of_birth" in subject.refusals
    assert not subject.scorable


def test_an_unparseable_date_of_birth_refuses():
    subject = resolve_subject(profile(dob="15/06/1980"), as_of=AS_OF)

    assert "date_of_birth" in subject.refusals
    assert not subject.scorable


def test_a_date_of_birth_in_the_future_refuses():
    subject = resolve_subject(profile(dob="2030-01-01"), as_of=AS_OF)

    assert "implausible_date_of_birth" in subject.refusals
    assert not subject.scorable


def test_an_implausibly_old_date_of_birth_refuses():
    subject = resolve_subject(profile(dob="1860-01-01"), as_of=AS_OF)

    assert "implausible_date_of_birth" in subject.refusals


def test_a_minor_refuses_because_adult_models_do_not_apply():
    """Adult reference ranges and an adult mortality model do not transfer to a
    child, and producing a number anyway would be confidently wrong."""
    subject = resolve_subject(profile(dob="2012-01-01"), as_of=AS_OF)

    assert subject.age_years < MINIMUM_AGE_YEARS
    assert "under_minimum_age" in subject.refusals
    assert not subject.scorable


def test_an_adult_on_their_birthday_is_scorable():
    subject = resolve_subject(profile(dob="2008-06-15"), as_of=AS_OF)

    assert subject.scorable
    assert subject.refusals == ()


# ── Sex ──────────────────────────────────────────────────────────────────────

def test_sex_is_read_from_the_sex_field():
    assert resolve_subject(profile(sex="Female"), as_of=AS_OF).sex == "female"


def test_sex_falls_back_to_the_gender_field_the_phone_actually_writes():
    """The profile editor offers both `sex` and `gender`, and the app's own
    calculators read `profile['sex'] ?? profile['gender']`. A backend that reads
    only `sex` sees None for every user who filled in the other box."""
    assert resolve_subject(profile(gender="male"), as_of=AS_OF).sex == "male"


def test_the_sex_field_wins_over_gender_when_both_are_present():
    subject = resolve_subject(profile(sex="female", gender="male"), as_of=AS_OF)

    assert subject.sex == "female"


def test_a_sex_we_cannot_map_is_unknown_rather_than_guessed():
    """Unknown is a correct answer. RangeResolver already returns no range for a
    sex-specific marker rather than grading someone against the wrong one."""
    subject = resolve_subject(profile(sex="prefer not to say"), as_of=AS_OF)

    assert subject.sex is None
    # Not a refusal: PhenoAge needs no sex term, so an unknown sex costs
    # sex-specific grading, not the whole score.
    assert subject.refusals == ()
    assert subject.scorable


# ── Pregnancy ────────────────────────────────────────────────────────────────

def test_pregnancy_refuses_to_score():
    """Reference ranges shift substantially in pregnancy and several models stop
    being valid. The plan's instruction is to refuse, not to score wrongly."""
    subject = resolve_subject(
        profile(conditions="Pregnant, 24 weeks"), as_of=AS_OF
    )

    assert "pregnancy" in subject.refusals
    assert not subject.scorable


def test_pregnancy_is_detected_from_the_phrasing_people_use():
    for text in ("second trimester", "28 weeks gestation", "currently expecting"):
        subject = resolve_subject(profile(conditions=text), as_of=AS_OF)
        assert "pregnancy" in subject.refusals, text


def test_a_past_pregnancy_in_a_history_field_does_not_refuse_forever():
    """`conditions` is labelled "Conditions / previous diseases", so it collects
    history as well as the present. Refusing on any mention would mean a woman
    who has ever been pregnant never gets a number again."""
    for text in (
        "post-pregnancy weight gain",
        "previous pregnancy 2019",
        "gestational diabetes in a past pregnancy",
        "not pregnant",
    ):
        subject = resolve_subject(profile(conditions=text), as_of=AS_OF)
        assert "pregnancy" not in subject.refusals, text


def test_an_unrelated_condition_does_not_refuse():
    subject = resolve_subject(profile(conditions="Hypothyroidism, CKD stage 2"),
                              as_of=AS_OF)

    assert subject.refusals == ()
    assert subject.scorable


# ── Shape ────────────────────────────────────────────────────────────────────

def test_refusals_are_sorted_and_deduplicated_so_a_hash_is_stable():
    """These reach `missing_inputs` and therefore `inputs_hash`. An unstable
    order would make the same inputs produce a different fingerprint."""
    subject = resolve_subject({"conditions": "pregnant"}, as_of=AS_OF)

    assert subject.refusals == ("date_of_birth", "pregnancy")


def test_an_empty_profile_refuses_without_raising():
    subject = resolve_subject(None, as_of=AS_OF)

    assert not subject.scorable
    assert "date_of_birth" in subject.refusals


def test_a_leap_day_birthday_does_not_raise_in_a_common_year():
    """`date.replace(year=...)` raises for 29 February in a non-leap year, which
    would crash scoring for one person in roughly 1,500 on most dates."""
    subject = resolve_subject(profile(dob="1988-02-29"), as_of=date(2026, 3, 1))

    assert subject.scorable
    assert 38.0 <= subject.age_years < 38.02
