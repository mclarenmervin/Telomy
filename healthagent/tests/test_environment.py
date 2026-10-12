"""The real source behind the environment form.

Today the app asks the user to type an AQI and a UV index in by hand and
nothing reads what they type. The interesting part of replacing that is not
the arithmetic — it is that answering "what was the air like where you were"
needs to know where somebody was, and this product has never had a reason to
know that.

Nothing here touches the network. The adapter returns a URL and a query and
the caller owns the HTTP, so there is no test in this file that could reach
a provider by accident.
"""

from datetime import date

import pytest

from app.analytics.environment import (
    COARSE_DECIMALS,
    EnvironmentUnavailable,
    coarsen,
    describe,
    parse_open_meteo,
    request_for,
)

DAY = date(2026, 10, 10)
# A public landmark coordinate, to six decimal places, as a phone would give it.
PRECISE_LAT, PRECISE_LON = 12.971599, 77.594566


def payload(us_aqi=None, uv=None, pm25=None, european=None):
    body = {}
    hourly = {}
    if us_aqi is not None:
        hourly["us_aqi"] = us_aqi
    if pm25 is not None:
        hourly["pm2_5"] = pm25
    if european is not None:
        hourly["european_aqi"] = european
    if hourly:
        body["hourly"] = hourly
    if uv is not None:
        body["daily"] = {"time": [DAY.isoformat()], "uv_index_max": uv}
    return body


def five_days_of_uv():
    """What the provider sends when `start_date` is not honoured: five days,
    ours first. The shape that makes a positional read look correct."""
    return {
        "daily": {
            "time": ["2026-10-10", "2026-10-11", "2026-10-12", "2026-10-13",
                     "2026-10-14"],
            "uv_index_max": [4.1, 10.2, 9.9, 8.0, 9.15],
        }
    }


# ── Location ─────────────────────────────────────────────────────────────────

def test_a_coordinate_is_rounded_to_a_city_and_not_a_street():
    assert coarsen(PRECISE_LAT, PRECISE_LON) == (13.0, 77.6)


def test_one_decimal_place_is_about_eleven_kilometres():
    """Written down because the number is the whole privacy argument. Two
    decimals is roughly a kilometre, which in a dense city is a
    neighbourhood and in a village is a house."""
    assert COARSE_DECIMALS == 1


def test_the_request_carries_only_a_rounded_coordinate():
    """Nothing identifies the person to the provider. A request naming
    somebody at a coordinate would put in a third party's logs exactly what
    the rounding keeps out of ours."""
    _, params = request_for(PRECISE_LAT, PRECISE_LON, DAY)

    assert params["latitude"] == 13.0
    assert params["longitude"] == 77.6
    assert not any(
        key in params for key in ("user", "user_id", "id", "apikey", "device")
    )


def test_the_stored_row_is_rounded_even_if_the_caller_forgot():
    """The rule holds against our own app being wrong, not only somebody
    else's. `coarsen` runs again on the way out."""
    snapshot = parse_open_meteo(
        payload(us_aqi=[70] * 24, uv=[8.0]), DAY, PRECISE_LAT, PRECISE_LON
    )

    assert (snapshot.latitude, snapshot.longitude) == (13.0, 77.6)


def test_the_day_asked_for_is_the_day_requested():
    _, params = request_for(13.0, 77.6, DAY)

    assert params["start_date"] == "2026-10-10"
    assert params["end_date"] == "2026-10-10"
    # UTC, so the day boundary is the one `observed_on` means. A
    # provider-guessed local timezone would shift which 24 hours were averaged.
    assert params["timezone"] == "UTC"


# ── A day, not a moment ──────────────────────────────────────────────────────

def test_the_uv_index_is_the_days_peak_and_not_the_current_hour():
    """The defect the first version of this module shipped with. The
    provider's `current.uv_index` at the hour a nightly job runs is 0.0; the
    day it was tested against peaked at 10.2. "Your UV exposure was 0" on a
    day somebody was outside at noon is not a rounding error."""
    snapshot = parse_open_meteo(payload(uv=[10.2]), DAY, 13.0, 77.6)

    assert snapshot.uv_index_max == 10.2


def test_air_quality_keeps_both_the_average_and_the_peak():
    """A day that averaged 90 and peaked at 180 for three hours is a
    different day from one that sat at 90 throughout, and which of them
    matters depends on what the person was doing."""
    hours = [60] * 21 + [180, 180, 180]
    snapshot = parse_open_meteo(payload(us_aqi=hours), DAY, 13.0, 77.6)

    assert snapshot.us_aqi_max == 180
    assert snapshot.us_aqi_mean == pytest.approx(75.0, abs=0.1)


def test_a_partial_day_says_how_much_of_it_was_seen():
    """A snapshot built from four hours is not a day, and whoever narrates
    it is entitled to know that before calling it one."""
    snapshot = parse_open_meteo(payload(us_aqi=[70, 72, 74, 76]), DAY, 13.0, 77.6)

    assert snapshot.hours_observed == 4


# ── Nothing becomes a zero ───────────────────────────────────────────────────

def test_a_missing_reading_is_absent_rather_than_zero():
    snapshot = parse_open_meteo(payload(us_aqi=[70] * 24), DAY, 13.0, 77.6)

    assert snapshot.us_aqi_mean == 70
    assert snapshot.uv_index_max is None


def test_a_genuine_zero_survives():
    """A UV index of 0.0 is a real reading on a dark winter day and must not
    be mistaken for a missing one."""
    snapshot = parse_open_meteo(payload(us_aqi=[70] * 24, uv=[0.0]), DAY, 13.0, 77.6)

    assert snapshot.uv_index_max == 0.0


def test_nothing_usable_raises_rather_than_storing_a_row_of_nulls():
    """A row of nulls is indistinguishable from a day the provider had no
    model output for, so we would store it once and never ask again."""
    with pytest.raises(EnvironmentUnavailable):
        parse_open_meteo({"hourly": {}}, DAY, 13.0, 77.6)


def test_a_response_that_is_not_an_object_raises():
    with pytest.raises(EnvironmentUnavailable):
        parse_open_meteo("<html>502 Bad Gateway</html>", DAY, 13.0, 77.6)


def test_a_non_numeric_reading_is_skipped_rather_than_crashing():
    snapshot = parse_open_meteo(
        payload(us_aqi=[70, "n/a", None, 80]), DAY, 13.0, 77.6
    )

    assert snapshot.us_aqi_mean == 75
    assert snapshot.hours_observed == 2


# ── Bands ────────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("aqi,band", [
    (30, "good"),
    (75, "moderate"),
    (130, "unhealthy for sensitive groups"),
    (180, "unhealthy"),
    (260, "very unhealthy"),
    (420, "hazardous"),
])
def test_the_us_aqi_bands_are_the_published_breakpoints(aqi, band):
    """Reading the scale, not interpreting somebody's health: the index is
    DEFINED by these breakpoints, which is why this needs no sign-off and a
    sentence about what the air did to this person would."""
    assert describe({"us_aqi_max": aqi})["us_aqi_band"] == band


@pytest.mark.parametrize("uv,band", [
    (1, "low"), (4, "moderate"), (6.5, "high"), (9, "very high"), (12, "extreme"),
])
def test_the_uv_bands_are_the_who_categories(uv, band):
    assert describe({"uv_index_max": uv})["uv_band"] == band


def test_a_band_is_absent_rather_than_guessed_for_a_missing_reading():
    described = describe({"us_aqi_max": None, "uv_index_max": None})

    assert described["us_aqi_band"] is None
    assert described["uv_band"] is None


def test_the_band_is_taken_from_the_peak_and_not_the_average():
    """Three hours at 180 is the thing worth saying about the day."""
    described = describe({"us_aqi_mean": 75.0, "us_aqi_max": 180.0})

    assert described["us_aqi_band"] == "unhealthy"


# ── Consent ──────────────────────────────────────────────────────────────────

from app.analytics.environment import (  # noqa: E402
    CONSENT_KEY,
    CONSENT_VALUES,
    LATITUDE_KEY,
    LONGITUDE_KEY,
    location_for,
)


def profile(**overrides):
    base = {CONSENT_KEY: "true", LATITUDE_KEY: "12.971599", LONGITUDE_KEY: "77.594566"}
    base.update(overrides)
    return base


def test_a_consenting_user_with_a_location_is_fetchable():
    assert location_for(profile()) == (13.0, 77.6)


def test_the_apps_actual_convention_is_the_string_true():
    """`user_preferences.profile` is a `Map<String, String>` on the phone, so
    every consent in this product is the STRING "true" -- `consentManual`,
    `consentWearable`, `consentHealthConnect`, all of them.

    The first version of this gate accepted only the boolean, which meant
    the sweep would have found nobody for the whole life of the feature and
    the only symptom would have been an environment screen that stayed
    empty. Found by going to write the app half.
    """
    assert location_for(profile(**{CONSENT_KEY: "true"})) is not None
    assert location_for(profile(**{CONSENT_KEY: True})) is not None


def test_no_consent_means_no_location_however_well_known_it_is():
    """The gate is here and nowhere else, so there is no code path that
    fetches without passing through it."""
    assert location_for(profile(**{CONSENT_KEY: False})) is None
    assert location_for(profile(**{CONSENT_KEY: "false"})) is None


def test_a_missing_consent_key_is_not_consent():
    stored = profile()
    del stored[CONSENT_KEY]

    assert location_for(stored) is None


@pytest.mark.parametrize("value", ["false", "False", 1, 0, "yes", "1", None, [], ""])
def test_nothing_but_an_explicit_yes_is_consent(value):
    """Two accepted spellings and an allowlist, NOT a truthiness check.

    `bool("false")` is True, and a JSON column full of client-written values
    is exactly where the string "false" turns up. The non-empty string "1"
    is refused for the same reason: it is a value nothing in this product
    writes, so accepting it could only ever mean something went wrong.
    """
    assert location_for(profile(**{CONSENT_KEY: value})) is None


def test_consent_without_a_location_is_not_a_location():
    assert location_for(profile(**{LATITUDE_KEY: None})) is None


def test_a_coordinate_that_is_not_a_number_is_refused():
    assert location_for(profile(**{LATITUDE_KEY: "somewhere nice"})) is None


def test_a_coordinate_off_the_planet_is_refused():
    assert location_for(profile(**{LATITUDE_KEY: 412.0})) is None


def test_an_empty_profile_is_not_an_error():
    assert location_for({}) is None
    assert location_for(None) is None


def test_the_location_handed_out_is_already_coarse():
    """Whatever the client stored, what leaves this function is rounded."""
    stored = profile(**{LATITUDE_KEY: 51.507351, LONGITUDE_KEY: -0.127758})

    assert location_for(stored) == (51.5, -0.1)


# ── The day asked for is the day stored ──────────────────────────────────────

def test_the_uv_value_is_matched_to_its_own_date():
    """Not taken positionally and not reduced with max. The provider returns
    five days by default and honours `start_date` only because we send it;
    if that were ever dropped, a positional read would return the wrong day
    and a max would return the sunniest of five. Neither is detectable
    downstream."""
    snapshot = parse_open_meteo(five_days_of_uv(), DAY, 13.0, 77.6)

    assert snapshot.uv_index_max == 4.1


def test_a_response_missing_the_day_asked_for_has_no_uv_rather_than_a_guess():
    body = five_days_of_uv()
    body["daily"]["time"][0] = "2026-09-01"

    with pytest.raises(EnvironmentUnavailable):
        parse_open_meteo(body, DAY, 13.0, 77.6)


def test_a_daily_block_with_no_dates_yields_no_uv():
    with pytest.raises(EnvironmentUnavailable):
        parse_open_meteo({"daily": {"uv_index_max": [10.2]}}, DAY, 13.0, 77.6)


# ── The nightly sweep ────────────────────────────────────────────────────────

from app.scheduler.environment_sweep import (  # noqa: E402
    due_locations,
    sweep_environment,
)
from tests.fakes import FakeSupabase  # noqa: E402

ALICE = "00000000-0000-0000-0000-00000000000a"
BOB = "00000000-0000-0000-0000-00000000000b"
CAROL = "00000000-0000-0000-0000-00000000000c"


def preference(user_id, **overrides):
    return {"user_id": user_id, "profile": profile(**overrides)}


def good_payload(day):
    return {
        "hourly": {"us_aqi": [70] * 24, "pm2_5": [20.0] * 24},
        "daily": {"time": [day], "uv_index_max": [9.4]},
    }


def recording_fetch(payload):
    calls = []

    def fetch(url, params):
        calls.append((url, params))
        return payload

    fetch.calls = calls
    return fetch


def test_two_people_in_one_city_are_one_request():
    """The point of rounding. It saves requests, and it means the provider
    cannot count our users even approximately."""
    profiles = [preference(ALICE), preference(BOB)]

    assert list(due_locations(profiles)) == [(13.0, 77.6)]
    assert due_locations(profiles)[(13.0, 77.6)] == [ALICE, BOB]


def test_somebody_who_did_not_consent_is_not_in_the_sweep():
    profiles = [preference(ALICE), preference(BOB, **{CONSENT_KEY: False})]

    assert due_locations(profiles) == {(13.0, 77.6): [ALICE]}


def test_the_sweep_stores_a_row_per_user_from_one_fetch():
    db = FakeSupabase({
        "user_preferences": [preference(ALICE), preference(BOB)],
        "environment_snapshots": [],
    })
    fetch = recording_fetch(good_payload((date.today() - __import__("datetime").timedelta(days=1)).isoformat()))

    result = sweep_environment(db, fetch)

    assert len(fetch.calls) == 1
    assert result["stored"] == 2
    assert {r["user_id"] for r in db.tables["environment_snapshots"]} == {ALICE, BOB}


def test_the_sweep_asks_for_yesterday():
    """A day's air quality is only complete once the day has ended, and
    today's hourly series is partly forecast."""
    import datetime as dt

    db = FakeSupabase({"user_preferences": [preference(ALICE)],
                       "environment_snapshots": []})
    yesterday = (dt.date.today() - dt.timedelta(days=1)).isoformat()
    fetch = recording_fetch(good_payload(yesterday))

    sweep_environment(db, fetch)

    assert fetch.calls[0][1]["start_date"] == yesterday


def test_nobody_consenting_means_no_request_at_all():
    db = FakeSupabase({
        "user_preferences": [preference(ALICE, **{CONSENT_KEY: False})],
        "environment_snapshots": [],
    })
    fetch = recording_fetch({})

    result = sweep_environment(db, fetch)

    assert fetch.calls == []
    assert result["stored"] == 0


def test_a_provider_outage_is_a_night_without_snapshots_not_a_crash():
    db = FakeSupabase({"user_preferences": [preference(ALICE)],
                       "environment_snapshots": []})

    def fetch(url, params):
        raise TimeoutError("the provider did not answer")

    result = sweep_environment(db, fetch)

    assert result["failed"] == 1
    assert db.tables["environment_snapshots"] == []


def test_an_unusable_response_does_not_store_a_row_of_nulls():
    db = FakeSupabase({"user_preferences": [preference(ALICE)],
                       "environment_snapshots": []})

    result = sweep_environment(db, FactoryEmpty())

    assert db.tables["environment_snapshots"] == []
    assert result["failed"] == 1


class FactoryEmpty:
    def __call__(self, url, params):
        return {"hourly": {}, "daily": {}}


def test_the_request_names_nobody():
    """One outbound call in the whole product, and it carries a rounded
    coordinate and nothing else."""
    import datetime as dt

    db = FakeSupabase({"user_preferences": [preference(ALICE)],
                       "environment_snapshots": []})
    yesterday = (dt.date.today() - dt.timedelta(days=1)).isoformat()
    fetch = recording_fetch(good_payload(yesterday))

    sweep_environment(db, fetch)

    _, params = fetch.calls[0]
    assert ALICE not in str(params)
    assert set(params) == {
        "latitude", "longitude", "hourly", "daily",
        "start_date", "end_date", "timezone",
    }


# ── The surface ──────────────────────────────────────────────────────────────

def test_the_loader_returns_a_days_conditions_with_their_bands():
    from app.common.context_loader import ContextLoader
    import datetime as dt

    yesterday = (dt.date.today() - dt.timedelta(days=1)).isoformat()
    loader = ContextLoader(FakeSupabase({"environment_snapshots": [{
        "user_id": ALICE, "observed_on": yesterday,
        "latitude": 13.0, "longitude": 77.6,
        "us_aqi_mean": 92.0, "us_aqi_max": 181.0, "european_aqi_mean": 55.0,
        "pm2_5_mean": 40.0, "pm10_mean": 60.0, "uv_index_max": 9.4,
        "hours_observed": 24, "provider": "open-meteo",
    }]}))

    out = loader.environment_snapshots(ALICE)

    assert out["status"] == "ok"
    assert out["items"][0]["us_aqi_band"] == "unhealthy"
    assert out["items"][0]["uv_band"] == "very high"
    assert out["items"][0]["provider"] == "open-meteo"


def test_another_users_conditions_are_not_reachable():
    from app.common.context_loader import ContextLoader
    import datetime as dt

    loader = ContextLoader(FakeSupabase({"environment_snapshots": [{
        "user_id": BOB, "observed_on": dt.date.today().isoformat(),
        "us_aqi_max": 181.0, "uv_index_max": 9.4, "hours_observed": 24,
        "provider": "open-meteo",
    }]}))

    assert loader.environment_snapshots(ALICE)["items"] == []


def test_no_snapshot_is_empty_and_not_clean_air():
    """"We have no snapshot" is almost always "the user gave us no location",
    and reporting it as clean air would be inventing a measurement."""
    from app.common.context_loader import ContextLoader

    out = ContextLoader(FakeSupabase({"environment_snapshots": []})).environment_snapshots(ALICE)

    assert out["status"] == "empty"
    assert out["items"] == []


def test_the_agent_tool_clamps_the_window_a_model_asks_for():
    from types import SimpleNamespace

    from app.agent.data_tools import UserScope, build_data_tools
    from app.common.context_loader import ContextLoader

    loader = ContextLoader(FakeSupabase({"environment_snapshots": []}))
    tool = {t.name: t for t in build_data_tools(loader)}["get_environment"]

    # Clamped rather than refused: a model asking for ten years of air
    # quality is a mistake to correct, not a turn to fail.
    assert tool.func(SimpleNamespace(context=UserScope(user_id=ALICE)), days=99999)
    assert tool.func(SimpleNamespace(context=UserScope(user_id=ALICE)), days=-1)


def test_the_app_and_the_server_agree_on_what_a_consent_looks_like():
    """Cross-language drift check, and the one that would have caught this.

    The app's profile is a `Map<String, String>`, so every consent it writes
    is the string "true" -- `profile['consentManual'] == 'true'` is the
    idiom, repeated across the health, devices and settings screens. A
    server gate that accepted only the boolean would find nobody, forever,
    with no symptom but an empty screen.
    """
    import re
    from pathlib import Path

    mobile = Path(__file__).resolve().parents[2] / "mobile" / "lib"
    written = set()
    for source in mobile.rglob("*.dart"):
        text = source.read_text()
        # `'consentWearable': 'true'` and `profile['consentManual'] == 'true'`
        written |= set(re.findall(r"'consent\w+':\s*'(\w+)'", text))
        written |= set(re.findall(r"\['consent\w+'\]\s*==\s*'(\w+)'", text))

    assert written, "no consent flag is written anywhere in the app"
    # Everything the app can ever mean by yes has to be something this gate
    # accepts.
    assert written <= set(str(v).lower() for v in CONSENT_VALUES) | {"false"}


def test_the_app_writes_the_profile_keys_the_server_reads():
    """The other half of the drift that already bit once.

    The app writes `coarseLatitude`; the server reads `coarseLatitude`. A
    typo in either is a feature that silently never runs — the sweep finds
    nobody, the screen stays empty, and nothing anywhere says why.
    """
    import re
    from pathlib import Path

    source = (
        Path(__file__).resolve().parents[2]
        / "mobile" / "lib" / "features" / "environment" / "providers"
        / "environment_provider.dart"
    ).read_text()

    declared = dict(
        re.findall(r"const (\w+Key) = '([^']+)';", source)
    )

    assert declared["consentLocationKey"] == CONSENT_KEY
    assert declared["coarseLatitudeKey"] == LATITUDE_KEY
    assert declared["coarseLongitudeKey"] == LONGITUDE_KEY


def test_every_city_the_app_offers_is_one_the_gate_accepts():
    """A list entry the server would refuse is a city somebody can pick and
    then get nothing from, with no error anywhere."""
    import re
    from pathlib import Path

    source = (
        Path(__file__).resolve().parents[2]
        / "mobile" / "lib" / "features" / "environment" / "data"
        / "coarse_places.dart"
    ).read_text()

    places = re.findall(
        r"CoarsePlace\('[^']+', '[^']+', (-?[\d.]+), (-?[\d.]+)\)", source
    )
    assert len(places) > 20, "the city list did not parse"

    for latitude, longitude in places:
        stored = profile(**{LATITUDE_KEY: latitude, LONGITUDE_KEY: longitude})
        resolved = location_for(stored)
        assert resolved is not None, f"{latitude},{longitude} is refused"
        # And already coarse: the app must not be shipping a precision the
        # server would have to round away.
        assert resolved == (float(latitude), float(longitude))


# ── The bands are read off the published scale, which is integer ────────────

def test_a_uv_index_is_banded_as_a_rounded_whole_number():
    """Found on a real screen: a UV peak of 10.2 was labelled "extreme".

    The WMO/WHO scale is defined on the UV index ROUNDED TO THE NEAREST
    WHOLE NUMBER -- 8 to 10 is very high and 11 upwards is extreme. 10.2
    rounds to 10, so it is very high. Calling it extreme overstates a
    health warning by a band, which is the wrong direction to be wrong in
    for a number somebody uses to decide whether to go outside.
    """
    assert describe({"uv_index_max": 10.2})["uv_band"] == "very high"
    assert describe({"uv_index_max": 10.0})["uv_band"] == "very high"
    assert describe({"uv_index_max": 10.4})["uv_band"] == "very high"


def test_eleven_is_where_extreme_starts():
    assert describe({"uv_index_max": 10.5})["uv_band"] == "extreme"
    assert describe({"uv_index_max": 11.0})["uv_band"] == "extreme"


def test_the_other_uv_boundaries_round_the_same_way():
    assert describe({"uv_index_max": 2.4})["uv_band"] == "low"
    assert describe({"uv_index_max": 2.5})["uv_band"] == "moderate"
    assert describe({"uv_index_max": 5.4})["uv_band"] == "moderate"
    assert describe({"uv_index_max": 5.5})["uv_band"] == "high"
    assert describe({"uv_index_max": 7.4})["uv_band"] == "high"
    assert describe({"uv_index_max": 7.5})["uv_band"] == "very high"


def test_an_aqi_is_banded_as_a_rounded_whole_number_too():
    """The US AQI is an integer by definition -- it is computed from
    breakpoints and reported whole."""
    assert describe({"us_aqi_max": 100.4})["us_aqi_band"] == "moderate"
    assert describe({"us_aqi_max": 100.5})["us_aqi_band"] == "unhealthy for sensitive groups"
