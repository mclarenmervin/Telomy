"""Who we are scoring, and when we decline to.

Every score that reasons about a *person* rather than a *reading* needs the same
three facts: how old they are, what sex their reference ranges should come from,
and whether they are in a state where the model stops being valid. Resolving
that in one place means the refusals are written once and tested once, instead
of being remembered at each call site.

The bias throughout is to **refuse rather than assume**. A biological age
produced from a guessed age, or for someone the model was never fitted on, is
worse than no number: it is a confident, specific, wrong claim that a person may
act on. `RangeResolver` already takes this position for sex-specific ranges and
this module takes it for the subject as a whole.

Note the two shapes of "no answer" here, which are deliberately different:

* **An unknown sex is not a refusal.** PhenoAge carries no sex term, so an
  unknown sex costs sex-specific *grading*, not the score. `RangeResolver`
  already returns no range in that case.
* **An unknown age is a refusal**, because a biological age is meaningless
  except relative to a chronological one.
"""

import re
from dataclasses import dataclass
from datetime import date

from app.common.timeparse import parse_ts

# Adult ranges and an adult mortality model do not transfer to a child. 18 is
# the line the rest of the product already draws, and a paediatric model is a
# separate piece of medical content, not a default.
MINIMUM_AGE_YEARS = 18

# Beyond this a date of birth is a typo, not a supercentenarian. Scoring on it
# would produce a biological age with a nonsense anchor.
MAX_PLAUSIBLE_AGE_YEARS = 120

# Refusal tokens. These land in `score_snapshots.missing_inputs`, so they are
# input names rather than sentences -- the wording a user sees belongs on screen,
# where it can be translated and where it has room to explain.
NO_DOB = "date_of_birth"
IMPLAUSIBLE_DOB = "implausible_date_of_birth"
UNDER_AGE = "under_minimum_age"
PREGNANCY = "pregnancy"

_SEX_ALIASES = {
    "male": "male", "m": "male", "man": "male", "boy": "male",
    "female": "female", "f": "female", "woman": "female", "girl": "female",
}

# Pregnancy screening over a free-text field.
#
# There is no structured pregnancy flag in the profile today -- the only place a
# user can say so is the free-text "Conditions / previous diseases" box. A
# keyword screen over prose is a weak signal and this is the honest limitation to
# record: **the correct fix is a structured field**, and until there is one this
# will both miss people who never typed it and occasionally refuse someone it
# should not.
#
# Given that, the direction of the error matters more than its rate. Refusing to
# score someone who is not pregnant costs them a number; scoring someone who is
# gives them a wrong one from ranges that do not apply. So an ambiguous match
# refuses.
#
# `gestation` only counts in the "28 weeks gestation" form, and `gravida` not at
# all. Bare "gestational" is nearly always "gestational diabetes" -- a named
# condition recorded as history -- and obstetric notation like G2P1 is a parity
# count, not a statement about now. Both would refuse permanently.
_PREGNANCY_TERMS = re.compile(
    r"\b(pregnan\w*|trimester|expecting|\d+\s*weeks?\s+gestation\w*)\b", re.I
)

# ...with the exception of history and negation, because the field explicitly
# collects "previous diseases". Without this, any woman who has ever recorded a
# pregnancy never gets a biological age again.
_NOT_CURRENT = re.compile(
    r"\b(not|non|no|never|post|after|previous|previously|past|prior|former|"
    r"formerly|pre|before|history|hx)\b[\s\-]*$",
    re.I,
)


@dataclass(frozen=True)
class Subject:
    """The person a score is about, plus the reasons we cannot produce one.

    `refusals` is sorted and deduplicated because it reaches `inputs_hash`
    through `missing_inputs`; an unstable order would make identical inputs
    fingerprint differently and break the reproducibility guarantee.
    """

    age_years: float | None
    sex: str | None
    refusals: tuple[str, ...] = ()

    @property
    def scorable(self) -> bool:
        return self.age_years is not None and not self.refusals


def _anniversary(dob: date, year: int) -> date:
    try:
        return dob.replace(year=year)
    except ValueError:
        # 29 February in a non-leap year. 28 February is the convention and the
        # alternative is an exception on one birthday in four.
        return dob.replace(year=year, day=28)


def _age_at(dob: date, as_of: date) -> float:
    """Exact age in years, fractional.

    Deliberately not `days / 365.25`: that approximation reads 17.9986 on
    someone's eighteenth birthday, so a minimum-age gate built on it turns an
    adult away for a day. Whole years come from the calendar and the remainder
    is the fraction travelled through the current year.
    """
    years = as_of.year - dob.year - ((as_of.month, as_of.day) < (dob.month, dob.day))
    last = _anniversary(dob, dob.year + years)
    following = _anniversary(dob, dob.year + years + 1)
    return years + (as_of - last).days / (following - last).days


def _dob_of(profile: dict) -> date | None:
    raw = profile.get("dob") or profile.get("dateOfBirth")
    if not raw:
        return None
    parsed = parse_ts(str(raw)[:10])
    return parsed.date() if parsed else None


def resolve_sex(profile: dict | None) -> str | None:
    """`male`, `female`, or None when we cannot say.

    Reads `sex` first and falls back to `gender`, because the profile editor
    offers both boxes and the app's own calculators already read
    `profile['sex'] ?? profile['gender']`. A backend reading only `sex` sees
    None for every user who filled in the other one.

    None is a real answer and not an error. The two fields are not the same
    question, so an unmappable value is left unmapped rather than forced into
    one of two buckets.
    """
    for key in ("sex", "gender"):
        value = str((profile or {}).get(key) or "").strip().lower()
        mapped = _SEX_ALIASES.get(value)
        if mapped:
            return mapped
    return None


def screen_for_pregnancy(text: str | None) -> bool:
    """Best-effort pregnancy detection in free text. See `_PREGNANCY_TERMS`.

    Each match is checked against the words immediately before it: "previous
    pregnancy" and "not pregnant" are history, "24 weeks pregnant" is not.
    """
    if not text or not text.strip():
        return False
    for match in _PREGNANCY_TERMS.finditer(text):
        # Just the run of words before the match -- enough to catch a qualifier,
        # short enough that a qualifier attached to some other clause earlier in
        # the sentence cannot suppress this one.
        preceding = text[max(0, match.start() - 24):match.start()]
        if not _NOT_CURRENT.search(preceding):
            return True
    return False


def resolve_subject(profile: dict | None, as_of: date) -> Subject:
    """The subject of a score on one date.

    `as_of` is the date the sample was collected, not today: a panel from 2019
    must be scored against the age its owner was in 2019. Using today's age
    would quietly flatter every historical upload.
    """
    profile = profile or {}
    refusals: set[str] = set()

    dob = _dob_of(profile)
    age: float | None = None
    if dob is None:
        refusals.add(NO_DOB)
    else:
        age = _age_at(dob, as_of)
        if age < 0 or age > MAX_PLAUSIBLE_AGE_YEARS:
            refusals.add(IMPLAUSIBLE_DOB)
            age = None
        elif age < MINIMUM_AGE_YEARS:
            refusals.add(UNDER_AGE)

    if screen_for_pregnancy(profile.get("conditions")):
        refusals.add(PREGNANCY)

    return Subject(
        age_years=age,
        sex=resolve_sex(profile),
        refusals=tuple(sorted(refusals)),
    )
