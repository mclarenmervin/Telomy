"""Where somebody was, coarsely, and what the air and the sun were doing.

The environment form in the app today asks the user to type an AQI and a UV
index in by hand, and nothing reads what they type. This is the real source
behind it.

### Location is the whole problem, so it is handled first

Everything else here is arithmetic over a public dataset. The sensitive part
is that answering "what was the air like where you were" requires knowing
where somebody was, and this product has had no reason to know that until
now.

Three rules, and the first two are enforced in code rather than promised:

**Coarse, always.** A coordinate is rounded to one decimal place before it is
stored or sent anywhere — about 11 km, which is a city and not a street. That
is enough to resolve an air-quality cell and not enough to resolve a home.
The precise fix never leaves the phone, and `coarsen` is applied again on
arrival, so a client that sent six decimals is corrected rather than trusted.

**Nothing identifies the person to the provider.** The request carries a
rounded coordinate and nothing else — no user id, no device id, no header
that distinguishes one user from another. A request that named somebody at a
coordinate would put in a third party's logs the thing the rounding exists to
keep out of ours.

**One provider, named in the row.** Every snapshot records who said it and
when, because "the AQI was 180" is a claim somebody else made and the user is
entitled to know who.

### Why a day and not a moment

A snapshot describes a day, and the first version of this module got that
wrong in a way worth recording: it stored the provider's *current* UV index,
which at the hour a nightly job runs is 0.0. The day it was tested against
had a peak of 10.2. "Your UV exposure was 0" on a day somebody was outside at
noon is not a rounding error, it is the opposite of the truth.

So UV comes from the provider's own daily maximum, and the air-quality
figures are aggregated here from the twenty-four hourly values — in ordinary
Python, because that is arithmetic and arithmetic is ours (P2). Both a mean
and a maximum are kept for AQI: a day that averaged 90 and peaked at 180 for
three hours is a different day from one that sat at 90 throughout, and which
of those matters depends on what the person was doing.

### What this does NOT do

It does not say what the air did to the person. A snapshot is context, in
exactly the sense a genetic variant is: the number sits beside what was
measured about them, and the connection between the two is a claim nobody has
reviewed. The AQI *band* is reported because it is a property of the index's
published definition rather than a judgement about this person — the index is
defined by its breakpoints — and the tool description forbids going further.
"""

import math
from dataclasses import dataclass
from datetime import date
from statistics import fmean

#: One decimal place, about 11 km. A city and not a street.
#:
#: Two decimals is roughly a kilometre, which in a dense city is a
#: neighbourhood and in a village is a house. One is the largest cell that
#: still resolves a different air-quality reading across a metro area.
COARSE_DECIMALS = 1

PROVIDER = "open-meteo"

#: Free for non-commercial use with attribution and no key. COMMERCIAL USE
#: NEEDS A PAID PLAN, which is a launch blocker rather than a code change and
#: is written here so it is found by whoever reads the adapter.
OPEN_METEO_URL = "https://air-quality-api.open-meteo.com/v1/air-quality"

#: Aggregated here from the hourly series.
HOURLY_FIELDS = ("us_aqi", "european_aqi", "pm2_5", "pm10")

#: Taken from the provider's own daily aggregate, because the peak is the
#: question and the provider knows when solar noon was.
DAILY_FIELDS = ("uv_index_max",)


class EnvironmentUnavailable(Exception):
    """The provider did not answer, or answered with nothing usable.

    Never swallowed into a zero. An AQI of 0 is pristine air, and "we could
    not look" is not pristine air.
    """


@dataclass(frozen=True)
class Snapshot:
    """One day's conditions at a coarse location."""

    observed_on: date
    latitude: float
    longitude: float
    us_aqi_mean: float | None
    us_aqi_max: float | None
    european_aqi_mean: float | None
    pm2_5_mean: float | None
    pm10_mean: float | None
    uv_index_max: float | None
    hours_observed: int
    provider: str = PROVIDER

    def as_row(self, user_id: str) -> dict:
        return {
            "user_id": user_id,
            "observed_on": self.observed_on.isoformat(),
            "latitude": self.latitude,
            "longitude": self.longitude,
            "us_aqi_mean": self.us_aqi_mean,
            "us_aqi_max": self.us_aqi_max,
            "european_aqi_mean": self.european_aqi_mean,
            "pm2_5_mean": self.pm2_5_mean,
            "pm10_mean": self.pm10_mean,
            "uv_index_max": self.uv_index_max,
            "hours_observed": self.hours_observed,
            "provider": self.provider,
        }


def coarsen(latitude, longitude) -> tuple[float, float]:
    """Round a coordinate to the cell we are willing to hold.

    Applied on the way in as well as on the way out. A client that sends six
    decimal places is corrected rather than trusted, because the rule has to
    hold against our own app being wrong as well as against somebody else's.
    """
    return (
        round(float(latitude), COARSE_DECIMALS),
        round(float(longitude), COARSE_DECIMALS),
    )


# ── The provider ─────────────────────────────────────────────────────────────

def request_for(latitude: float, longitude: float, observed_on: date) -> tuple[str, dict]:
    """The URL and query for one coarse location on one day.

    Returned rather than fetched, so the caller owns the HTTP: every test in
    this module runs against a fake, and nothing here can reach the network
    by accident.
    """
    coarse_lat, coarse_lon = coarsen(latitude, longitude)
    return OPEN_METEO_URL, {
        "latitude": coarse_lat,
        "longitude": coarse_lon,
        "hourly": ",".join(HOURLY_FIELDS),
        "daily": ",".join(DAILY_FIELDS),
        "start_date": observed_on.isoformat(),
        "end_date": observed_on.isoformat(),
        # UTC so the day boundary is the same one `observed_on` means. A
        # provider-guessed local timezone would silently shift which 24 hours
        # were averaged.
        "timezone": "UTC",
    }


def _number(value) -> float | None:
    """A reading, or None. Never a zero for a missing one.

    A UV index of 0.0 is a real reading at night and must survive; an absent
    one must not become it.
    """
    if value is None or isinstance(value, bool):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _series(payload: dict, block: str, field: str) -> list[float]:
    values = ((payload.get(block) or {}).get(field)) or []
    if not isinstance(values, list):
        return []
    return [n for n in (_number(v) for v in values) if n is not None]


def _on_day(payload: dict, block: str, field: str, observed_on: date) -> float | None:
    """The one value whose own date is the day we asked about.

    Matched rather than taken positionally or reduced with `max`. The
    provider returns five days by default and honours `start_date` only
    because we send it; if that parameter were ever dropped, a positional
    read would quietly return today's forecast for yesterday's question and
    a `max` would return the sunniest of the five. Both are wrong in a way
    nothing downstream could detect.
    """
    block_data = payload.get(block) or {}
    days = block_data.get("time") or []
    values = block_data.get(field) or []
    if not isinstance(days, list) or not isinstance(values, list):
        return None
    wanted = observed_on.isoformat()
    for day, value in zip(days, values):
        if str(day) == wanted:
            return _number(value)
    return None


def parse_open_meteo(payload, observed_on: date, latitude: float,
                     longitude: float) -> Snapshot:
    """One provider response into one day's snapshot.

    Raises rather than returning a row of nulls when nothing usable came
    back: a row of nulls is indistinguishable from a day the provider had no
    model output for, so we would store it once and never ask again.
    """
    if not isinstance(payload, dict):
        raise EnvironmentUnavailable("the provider did not return an object")

    us_aqi = _series(payload, "hourly", "us_aqi")
    european = _series(payload, "hourly", "european_aqi")
    pm25 = _series(payload, "hourly", "pm2_5")
    pm10 = _series(payload, "hourly", "pm10")
    uv = _on_day(payload, "daily", "uv_index_max", observed_on)

    if not any((us_aqi, european, pm25, pm10)) and uv is None:
        raise EnvironmentUnavailable("the provider returned no usable readings")

    coarse_lat, coarse_lon = coarsen(latitude, longitude)
    return Snapshot(
        observed_on=observed_on,
        latitude=coarse_lat,
        longitude=coarse_lon,
        us_aqi_mean=round(fmean(us_aqi), 1) if us_aqi else None,
        us_aqi_max=max(us_aqi) if us_aqi else None,
        european_aqi_mean=round(fmean(european), 1) if european else None,
        pm2_5_mean=round(fmean(pm25), 1) if pm25 else None,
        pm10_mean=round(fmean(pm10), 1) if pm10 else None,
        # The day's peak, which is what a UV index is asked about. The
        # provider supplies it rather than us, because it knows when solar
        # noon was at that cell -- and it is matched to the day by its own
        # date rather than by position.
        uv_index_max=uv,
        # How much of the day we actually saw. A snapshot built from four
        # hours is not a day, and the caller is entitled to know before
        # narrating it as one.
        hours_observed=len(us_aqi or pm25 or european or pm10),
    )


# ── Bands ────────────────────────────────────────────────────────────────────
#
# A property of each index's published definition rather than a judgement
# about a person. The US AQI is *defined* by these breakpoints -- saying 160
# is "unhealthy" is reading the scale, not interpreting somebody's health --
# which is why this needs no clinical sign-off, while a sentence about what
# the air did to this user would.

#: (upper bound inclusive, label). US EPA AQI breakpoints.
US_AQI_BANDS = (
    (50, "good"),
    (100, "moderate"),
    (150, "unhealthy for sensitive groups"),
    (200, "unhealthy"),
    (300, "very unhealthy"),
    (500, "hazardous"),
)

#: WHO/WMO UV index exposure categories.
UV_BANDS = (
    (2, "low"),
    (5, "moderate"),
    (7, "high"),
    (10, "very high"),
    (100, "extreme"),
)


def _band(bands, value) -> str | None:
    """The published band for a reading.

    **Rounded to a whole number first**, because both scales are defined
    that way: the WMO/WHO UV index is reported to the nearest integer, and
    the US AQI is an integer by construction. Found on a real screen, where
    a UV peak of 10.2 was labelled "extreme" -- the WHO calls 8 to 10 very
    high and 11 upwards extreme, so 10.2 is a very high day. Overstating a
    sun-exposure warning by a band is the wrong direction to be wrong in for
    a number somebody uses to decide whether to go outside.

    Half-up, written out rather than using `round`: Python rounds halves to
    even, so `round(10.5)` is 10 and `round(11.5)` is 12, which is not what
    "nearest whole number" means to anybody reading a UV forecast and gives
    two different answers at two adjacent boundaries. At an exact half on a
    warning scale, up is also the safer of the two.
    """
    if value is None:
        return None
    whole = math.floor(value + 0.5)
    for upper, label in bands:
        if whole <= upper:
            return label
    return bands[-1][1]


def describe(snapshot: dict) -> dict:
    """A stored row with its published bands attached."""
    return {
        **snapshot,
        "us_aqi_band": _band(US_AQI_BANDS, _number(snapshot.get("us_aqi_max"))),
        "uv_band": _band(UV_BANDS, _number(snapshot.get("uv_index_max"))),
    }


# ── Consent, and who is due a fetch ──────────────────────────────────────────
#
# The gate is here rather than in the scheduler, so that there is exactly one
# function that decides whether somebody's location may be sent anywhere and
# no code path that fetches without passing through it.

#: The profile key. Consent lives on the profile with every other consent in
#: this product rather than beside the data it authorises -- a flag stored
#: next to its own data is one somebody eventually reads from the wrong row.
CONSENT_KEY = "consentLocation"

#: The only two values that mean yes.
#:
#: An allowlist and NOT a truthiness check, for a reason that is easy to get
#: backwards: `bool("false")` is True, and a JSON column full of
#: client-written values is precisely where the string "false" turns up.
#:
#: The string is here because it is what the app actually writes.
#: `user_preferences.profile` is a `Map<String, String>` on the phone, so
#: every consent in this product is the string "true" -- `consentManual`,
#: `consentWearable`, `consentHealthConnect`, all of them. The first version
#: of this gate took the boolean only, which would have meant the nightly
#: sweep found nobody for the entire life of the feature, with no symptom
#: except an environment screen that stayed empty.
CONSENT_VALUES = (True, "true")

#: Where the coarse home location is kept, when the user has given one.
LATITUDE_KEY = "coarseLatitude"
LONGITUDE_KEY = "coarseLongitude"


def location_for(profile) -> tuple[float, float] | None:
    """This person's coarse location, or None if we may not use it.

    Returns None for every reason a fetch must not happen — no consent, no
    coordinate, a coordinate that is not a number — rather than distinguishing
    them, because every one of them is the same answer to the only question
    the caller is asking.
    """
    profile = profile or {}
    given = profile.get(CONSENT_KEY)
    # Compared by identity for the boolean and by value for the string, so
    # that `1 == True` cannot sneak the number one through as a yes.
    if not any(
        given is accepted or (isinstance(given, str) and given == accepted)
        for accepted in CONSENT_VALUES
    ):
        return None

    latitude, longitude = profile.get(LATITUDE_KEY), profile.get(LONGITUDE_KEY)
    if latitude is None or longitude is None:
        return None
    try:
        coarse = coarsen(latitude, longitude)
    except (TypeError, ValueError):
        return None
    if not (-90 <= coarse[0] <= 90 and -180 <= coarse[1] <= 180):
        return None
    return coarse
