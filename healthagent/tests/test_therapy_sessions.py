"""Safety-gated therapy booking, execution and event reconciliation."""

from datetime import UTC, datetime, timedelta

import pytest

from app.clinical.therapy_sessions import (
    SessionConflict,
    SessionForbidden,
    SessionSafetyRefused,
    add_checkin,
    book_session,
    finish_session,
    schedule_session,
    start_session,
)
from tests.fakes import FakeSupabase

PATIENT = "10000000-0000-4000-8000-000000000001"
OTHER = "10000000-0000-4000-8000-000000000009"
CENTRE = "20000000-0000-4000-8000-000000000001"
SAFE = {"pregnancy_status": "not_pregnant", "pacemaker": False,
        "uncontrolled_blood_pressure": False, "recent_cardiac_event": False,
        "raynaud": False, "untreated_pneumothorax": False, "dvt": False,
        "g6pd_deficiency": False, "coronary_plaque": False,
        "alcohol_today": False, "medications": [], "medications_known": True}


def db(slug="sauna"):
    return FakeSupabase({
        "profiles": [{"id": PATIENT, "app_role": "member"}, {"id": OTHER, "app_role": "member"}],
        "centre_memberships": [{"id": "m1", "centre_id": CENTRE, "user_id": PATIENT,
                                "member_kind": "patient", "status": "active", "left_at": None}],
        "therapy_catalogue": [{"id": "cat-1", "slug": slug, "version": 1,
                               "publication_status": "published"}],
        "therapy_plans": [{"id": "plan-1", "patient_id": PATIENT, "centre_id": CENTRE,
                           "status": "signed", "version": 1}],
        "therapy_plan_items": [{"id": "item-1", "plan_id": "plan-1", "catalogue_id": "cat-1",
                                "position": 1, "disposition": "proposed",
                                "prescribed_dose": {"duration_minutes": 20}, "frequency": {}}],
        "centre_therapy_offerings": [{"id": "offer-1", "centre_id": CENTRE,
                                      "catalogue_id": "cat-1", "status": "active"}],
        "therapy_service_sessions": [], "therapy_safety_checks": [],
        "therapy_checkins": [], "events": [],
    })


def book(store, facts=SAFE, key="book-1"):
    return book_session(store, PATIENT, "item-1", "offer-1", key, facts,
                        (datetime.now(UTC) + timedelta(days=1)).isoformat())


def test_booking_and_start_both_fail_closed_on_new_contraindications():
    with pytest.raises(SessionSafetyRefused, match="alcohol_today"):
        book(db(), {**SAFE, "alcohol_today": True})
    store = db()
    session = book(store)
    with pytest.raises(SessionSafetyRefused, match="alcohol_today"):
        start_session(store, PATIENT, session["id"], {**SAFE, "alcohol_today": True})
    assert store.tables["therapy_service_sessions"][0]["status"] == "refused"


def test_booking_is_idempotent_and_preserves_prescribed_dose():
    store = db()
    first = book(store)
    again = book(store)
    assert first["id"] == again["id"]
    assert len(store.tables["therapy_service_sessions"]) == 1
    assert first["prescribed_dose"] == {"duration_minutes": 20}


@pytest.mark.parametrize("disposition", ["excluded_safety", "removed"])
def test_booking_refuses_items_left_out_of_the_signed_regimen(disposition):
    store = db()
    store.tables["therapy_plan_items"][0]["disposition"] = disposition

    with pytest.raises(SessionConflict, match="active regimen"):
        book(store)

    assert store.tables["therapy_service_sessions"] == []
    assert store.tables["therapy_safety_checks"] == []


def test_centre_owner_can_schedule_a_safe_signed_item_for_the_patient():
    store = db()
    owner = "10000000-0000-4000-8000-000000000003"

    result = schedule_session(
        store, owner, CENTRE, PATIENT, "item-1", "offer-1", "centre-book-1",
        SAFE, (datetime.now(UTC) + timedelta(days=1)).isoformat(),
    )

    assert result["patient_id"] == PATIENT
    assert result["centre_id"] == CENTRE
    assert result["created_by"] == owner


def test_centre_owner_cannot_schedule_an_item_from_another_centre():
    store = db()

    with pytest.raises(SessionForbidden, match="selected centre"):
        schedule_session(
            store, "owner", "another-centre", PATIENT, "item-1", "offer-1",
            "centre-book-2", SAFE, None,
        )


def test_start_finish_preserve_delivered_dose_and_emit_exactly_one_event():
    store = db()
    session = book(store)
    started = start_session(store, PATIENT, session["id"], SAFE)
    finished = finish_session(store, PATIENT, session["id"], {"duration_minutes": 17})
    retried = finish_session(store, PATIENT, session["id"], {"duration_minutes": 17})
    assert started["status"] == "started"
    assert finished["delivered_dose"] == {"duration_minutes": 17}
    assert retried["event_id"] == finished["event_id"]
    assert len(store.tables["events"]) == 1
    assert store.tables["events"][0]["event_type"] == "sauna"


def test_completion_uses_the_catalogue_event_type_not_its_display_slug():
    store = db(slug="red_light")
    store.tables["therapy_catalogue"][0]["event_type"] = "red_light_therapy"
    session = book(store)
    start_session(store, PATIENT, session["id"], SAFE)

    finish_session(store, PATIENT, session["id"], {"duration_minutes": 12})

    assert store.tables["events"][0]["event_type"] == "red_light_therapy"


def test_only_the_patient_can_control_their_session_and_two_checkins_is_the_limit():
    store = db()
    session = book(store)
    with pytest.raises(SessionForbidden):
        start_session(store, OTHER, session["id"], SAFE)
    add_checkin(store, PATIENT, session["id"], "v1", 1, "felt", {"value": "calm"})
    add_checkin(store, PATIENT, session["id"], "v1", 2, "would_repeat", {"value": True})
    with pytest.raises(SessionConflict, match="two"):
        add_checkin(store, PATIENT, session["id"], "v1", 3, "extra", {"value": 1})
