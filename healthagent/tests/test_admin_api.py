"""The platform admin surface.

The fourth role, and the only one with nothing in the prototype to port from.
What it must do is already visible in this codebase's own failure modes:
`stranded_total` exists because there is no console to claim a draft, fifty
catalog entries are blocked on a signature with no interface to collect one,
and DPDP gives a user erasure rights somebody has to be able to honour.

Two properties are the phase and not a checkbox, and both have their own
section below.

**It reads counts, not people.** `stranded_total` is a number. Queue depth is
a number. Nothing on this surface returns a draft body, a measurement, a
conversation or a genotype, and the test asserts that against a database
holding all four. The programme's risk table calls the failure "the admin role
becomes a God account", and the answer cannot be a filter somebody has to
remember to write — so there is a test here that reads the whole response as
text and looks for the sentences.

**It cannot sign anything.** The admin collects a signature; a registered
clinician makes it. An admin filing a signature in a clinician's name is the
one thing the whole surface exists to make impossible, so the signoff route
admits `doctor` and refuses `admin` — which reads backwards until you
remember what a signature is for.
"""

import json
from datetime import datetime, timedelta, timezone

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.clinical import reviewable
from app.common.supabase_client import get_supabase_client
from app.gateway.api.admin import router
from app.gateway.auth import current_user_id
from tests.fakes import FakeSupabase

ADMIN = "00000000-0000-0000-0000-0000000000ad"
DOCTOR = "00000000-0000-0000-0000-0000000000d0"
MEMBER = "00000000-0000-0000-0000-0000000000me"

NOW = datetime(2026, 10, 12, 9, 0, tzinfo=timezone.utc)

#: A licence twenty days from *now*, not from a frozen NOW. `days_left` is
#: computed with `(expires - now).days`, which truncates, so a fixture pinned
#: to a date reports 19 once the clock passes that time of day — the same way
#: the concierge's daily-cap fixture rotted overnight. The extra hour is the
#: margin that makes the truncation land where the test expects.
LICENCE_EXPIRES = datetime.now(timezone.utc) + timedelta(days=20, hours=1)

SECRET_BODY = "Your ferritin suggests something nobody has reviewed yet."
SECRET_QUESTION = "am I going to be all right?"


def profiles():
    return [
        {"id": ADMIN, "full_name": "Ops", "app_role": "admin"},
        {"id": DOCTOR, "full_name": "Dr A. Rao", "app_role": "doctor"},
        {"id": MEMBER, "full_name": "Alex", "app_role": "member"},
    ]


def stranded_draft(**overrides):
    """A flagged draft that expired: the one that can never be delivered."""
    row = {
        "id": "dddddddd-0000-4000-8000-00000000000d",
        "user_id": MEMBER,
        "kind": "lab_finding",
        "title": "Ferritin",
        "body": SECRET_BODY,
        "evidence": [],
        "routing_flags": ["clinician_queue"],
        "status": "expired",
        "claimed_by": None,
        "claimed_at": None,
        "sla_due_at": (NOW - timedelta(days=2)).isoformat(),
    }
    row.update(overrides)
    return row


def populated():
    return FakeSupabase({
        "profiles": profiles(),
        "clinical_drafts": [
            stranded_draft(),
            stranded_draft(id="dddddddd-0000-4000-8000-00000000000e",
                           status="queued", routing_flags=[]),
            stranded_draft(id="dddddddd-0000-4000-8000-00000000000f",
                           status="in_review"),
        ],
        "insights": [],
        "clinicians": [{
            "user_id": DOCTOR,
            "full_name": "Dr A. Rao",
            "registration_number": "KMC/12345",
            "registration_body": "Karnataka Medical Council",
            "status": "active",
            "licence_expires_at": LICENCE_EXPIRES.isoformat(),
        }],
        "health_measurements": [{
            "user_id": MEMBER, "measurement_type": "resting_heart_rate",
            "value": 58.0, "unit": "bpm",
            "recorded_at": NOW.isoformat(), "source": "wearable",
        }],
        "chat_turns": [{
            "user_id": MEMBER, "asked": SECRET_QUESTION, "answered": "Yes.",
            "route": "answered", "model": "m",
            "created_at": NOW.isoformat(),
        }],
        "genetic_variants": [{
            "user_id": MEMBER, "rsid": "rs1801133", "genotype": "CT",
        }],
        "admin_actions": [{
            "id": "aaaaaaaa-0000-4000-8000-00000000000a",
            "actor_id": ADMIN, "action": "signoff_recorded",
            "subject_kind": "catalog_entry", "subject_id": "albumin",
            "detail": {}, "created_at": NOW.isoformat(),
        }],
        "catalog_signoffs": [],
    })


def client_for(db, user_id=ADMIN):
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[current_user_id] = lambda: user_id
    app.dependency_overrides[get_supabase_client] = lambda: db
    return TestClient(app)


# ── The dashboard ────────────────────────────────────────────────────────────

def test_the_dashboard_shows_stranded_total():
    """It has been the number that says the product is lying since F5:
    drafts flagged, expired and undeliverable because no console exists to
    claim them. F9 is the first phase that can show it to somebody who could
    act, and it belongs there before the queue has a single real user."""
    body = client_for(populated()).get("/api/v1/admin/platform").json()

    assert body["queue"]["stranded_total"] == 1


def test_the_dashboard_shows_the_queue_depth():
    body = client_for(populated()).get("/api/v1/admin/platform").json()

    # `queued` and `in_review`. The expired flagged one is not waiting on
    # anybody any more, which is exactly why it is counted separately.
    assert body["queue"]["depth"] == 2


def test_the_dashboard_counts_the_unsigned_catalogue():
    body = client_for(populated()).get("/api/v1/admin/platform").json()

    assert body["catalogue"]["unsigned"] == reviewable.summary()["unsigned"]
    assert body["catalogue"]["catalogues"]["biomarkers"]["unsigned"] == 33


def test_the_dashboard_counts_the_roles():
    body = client_for(populated()).get("/api/v1/admin/platform").json()

    assert body["roles"] == {"admin": 1, "doctor": 1, "centre": 0, "member": 1}


def test_the_dashboard_names_a_licence_about_to_lapse():
    """A lapse should be noticed before it becomes a refused signature, which
    is what `clinician_may_sign` turns it into at the worst moment."""
    body = client_for(populated()).get("/api/v1/admin/platform").json()

    lapsing = body["clinicians"]["expiring_soon"]
    assert lapsing[0]["registration_number"] == "KMC/12345"
    assert lapsing[0]["days_left"] == 20


def test_the_dashboard_says_how_many_clinicians_there_are():
    """One, and it is a fixture. Every draft strands until that changes, and
    the number is the honest headline of the whole surface."""
    body = client_for(populated()).get("/api/v1/admin/platform").json()

    assert body["clinicians"]["active"] == 1


# ── It reads counts, not people ──────────────────────────────────────────────

def test_the_dashboard_returns_no_draft_body_and_no_question_anybody_asked():
    """Read as text rather than field by field, deliberately. A later change
    that nested a draft under a new key would pass a field-by-field assertion
    and fail this one."""
    raw = client_for(populated()).get("/api/v1/admin/platform").text

    assert SECRET_BODY not in raw
    assert SECRET_QUESTION not in raw
    assert "rs1801133" not in raw
    assert "58" not in raw.replace('"days_left":20', "")


def test_the_dashboard_does_not_name_the_member_a_draft_is_about():
    """`stranded_total` is a count. Which people are behind it is a question
    with a different answer and a consent row in front of it, and F9 has
    nowhere to record one."""
    raw = client_for(populated()).get("/api/v1/admin/platform").text

    assert MEMBER not in raw


def test_the_dashboard_never_moves_the_queue_along():
    """The sweep's job, not a GET's. A dashboard that advanced the state
    machine would make reading it a side effect and two admins refreshing
    would race."""
    db = populated()
    before = json.dumps(db.tables["clinical_drafts"], sort_keys=True)

    client_for(db).get("/api/v1/admin/platform")

    assert json.dumps(db.tables["clinical_drafts"], sort_keys=True) == before


# ── Who reaches it ───────────────────────────────────────────────────────────

def test_a_member_cannot_reach_the_admin_dashboard():
    assert client_for(populated(), MEMBER).get(
        "/api/v1/admin/platform").status_code == 403


def test_a_doctor_cannot_reach_the_admin_dashboard():
    """The doctor's surface is F10's and it is a different surface. A role
    that can read platform health because it is also clinical is how the two
    axes start to blur."""
    assert client_for(populated(), DOCTOR).get(
        "/api/v1/admin/platform").status_code == 403


def test_a_member_cannot_read_the_admin_trail():
    assert client_for(populated(), MEMBER).get(
        "/api/v1/admin/audit").status_code == 403


def test_the_admin_trail_includes_the_reading_admin_s_own_actions():
    """No "except mine" clause, here or in the policy behind it."""
    body = client_for(populated()).get("/api/v1/admin/audit").json()

    assert [a["action"] for a in body["items"]] == ["signoff_recorded"]
    assert body["items"][0]["actor_id"] == ADMIN


# ── The catalogue surface ────────────────────────────────────────────────────

def test_the_catalogue_lists_all_five_files():
    body = client_for(populated()).get("/api/v1/admin/catalogue").json()

    assert [c["name"] for c in body["catalogues"]] == [
        "biomarkers", "supplements", "correlations", "therapies", "variants",
    ]


def test_an_entry_carries_the_hash_a_signature_has_to_be_over():
    body = client_for(populated()).get("/api/v1/admin/catalogue").json()

    entry = body["catalogues"][0]["entries"][0]
    assert len(entry["fingerprint"]) == 64
    assert entry["signed"] is False
    assert entry["label"]


def test_the_catalogue_names_the_file_to_commit():
    body = client_for(populated()).get("/api/v1/admin/catalogue").json()

    assert body["catalogues"][0]["path"].endswith("biomarkers.v1.yaml")


def test_a_member_cannot_read_the_catalogue_surface():
    assert client_for(populated(), MEMBER).get(
        "/api/v1/admin/catalogue").status_code == 403


# ── Collecting a signature ───────────────────────────────────────────────────

def signoff_payload(catalogue="variants", **overrides):
    """A well-formed signature for the first entry of a catalogue.

    Falls back to a syntactically valid hash for a catalogue that does not
    exist, so that the route is the thing refusing it rather than this
    helper.
    """
    known = reviewable.get(catalogue)
    entry = known.entries[0] if known else None
    payload = {
        "catalogue": catalogue,
        "entry_id": entry.entry_id if entry else "whatever",
        "content_sha256": entry.fingerprint if entry else "a" * 64,
    }
    payload.update(overrides)
    return payload


def test_a_clinician_records_a_signature():
    db = populated()

    response = client_for(db, DOCTOR).post(
        "/api/v1/admin/catalogue/signoff", json=signoff_payload())

    assert response.status_code == 201
    row = db.tables["catalog_signoffs"][0]
    assert row["clinician_id"] == DOCTOR
    assert row["catalog"] == "variants"
    assert row["action"] == "signed"


def test_the_signature_records_the_catalogue_version_that_was_signed():
    db = populated()

    client_for(db, DOCTOR).post(
        "/api/v1/admin/catalogue/signoff", json=signoff_payload())

    assert db.tables["catalog_signoffs"][0]["catalog_version"] == "variants.v1"


def test_the_clinician_id_comes_from_the_token_and_not_the_body():
    """CLAUDE.md's rule, which is about tools and is the same rule here: a
    signature whose signatory is a body parameter is a signature anybody can
    forge."""
    db = populated()

    client_for(db, DOCTOR).post(
        "/api/v1/admin/catalogue/signoff",
        json=signoff_payload(clinician_id=ADMIN, reviewer="Somebody Else"),
    )

    assert db.tables["catalog_signoffs"][0]["clinician_id"] == DOCTOR
    assert "reviewer_name" not in db.tables["catalog_signoffs"][0]


def test_an_admin_cannot_sign_clinical_content():
    """Reads backwards and is the point of the whole surface. The admin
    collects the signature; the clinician makes it. Open question 8 is about
    finding the clinician, and no interface can answer it."""
    db = populated()

    response = client_for(db, ADMIN).post(
        "/api/v1/admin/catalogue/signoff", json=signoff_payload())

    assert response.status_code == 403
    assert db.tables["catalog_signoffs"] == []


def test_a_member_cannot_sign_clinical_content():
    db = populated()

    assert client_for(db, MEMBER).post(
        "/api/v1/admin/catalogue/signoff",
        json=signoff_payload()).status_code == 403


def test_a_signature_over_a_hash_that_has_moved_is_refused():
    """Signing text you have not read, refused at the door rather than
    discovered when the loader ignores it."""
    db = populated()

    response = client_for(db, DOCTOR).post(
        "/api/v1/admin/catalogue/signoff",
        json=signoff_payload(content_sha256="0" * 64),
    )

    assert response.status_code == 409
    assert db.tables["catalog_signoffs"] == []


def test_a_signature_for_an_entry_nobody_declared_is_refused():
    db = populated()

    response = client_for(db, DOCTOR).post(
        "/api/v1/admin/catalogue/signoff",
        json=signoff_payload(entry_id="rs000000000"),
    )

    assert response.status_code == 409


def test_a_signature_for_a_file_nobody_reviews_is_refused():
    db = populated()

    response = client_for(db, DOCTOR).post(
        "/api/v1/admin/catalogue/signoff",
        json=signoff_payload(catalogue="horoscopes"),
    )

    assert response.status_code == 409


# ── Rendering the block to commit ────────────────────────────────────────────

def recorded(entry, catalogue="variants", action="signed"):
    return {
        "id": "ssssssss-0000-4000-8000-00000000000s",
        "catalog": catalogue,
        "catalog_version": "variants.v1",
        "entry_id": entry.entry_id,
        "content_sha256": entry.fingerprint,
        "clinician_id": DOCTOR,
        "action": action,
        "reviewer_name": "Dr A. Rao",
        "reviewer_registration": "KMC/12345",
        "signed_at": NOW.isoformat(),
        "seq": 1,
        "notes": "fine" if action == "withdrawn" else None,
    }


def test_the_block_renders_from_the_recorded_signatures():
    """The last step of collecting a signature is a human committing a file,
    so the surface hands them the exact text."""
    entry = reviewable.get("variants").entries[0]
    db = populated()
    db.tables["catalog_signoffs"] = [recorded(entry)]

    body = client_for(db).get("/api/v1/admin/catalogue/variants/block").json()

    assert entry.entry_id in body["block"]
    assert "Dr A. Rao, KMC/12345" in body["block"]
    assert body["path"].endswith("variants.v1.yaml")


def test_a_withdrawn_signature_is_not_rendered():
    entry = reviewable.get("variants").entries[0]
    db = populated()
    db.tables["catalog_signoffs"] = [recorded(entry, action="withdrawn")]

    body = client_for(db).get("/api/v1/admin/catalogue/variants/block").json()

    assert body["block"] is None
    assert body["signatures"] == 0


def test_a_block_with_nothing_signed_says_so_rather_than_rendering_an_empty_one():
    """An empty `clinical_review:` block committed over a real one would
    withdraw every signature in the file."""
    body = client_for(populated()).get(
        "/api/v1/admin/catalogue/variants/block").json()

    assert body["block"] is None


def test_a_stale_recorded_signature_is_reported_rather_than_rendered():
    """A hash recorded against content that has since been edited. The
    signature is real and no longer applies, and committing it would put a
    clinician's name in git against a block the loader ignores."""
    entry = reviewable.get("variants").entries[0]
    db = populated()
    stale = recorded(entry)
    stale["content_sha256"] = "0" * 64
    db.tables["catalog_signoffs"] = [stale]

    response = client_for(db).get("/api/v1/admin/catalogue/variants/block")

    assert response.status_code == 409
    assert "has changed since it was signed" in response.json()["detail"]


def test_a_member_cannot_read_the_block():
    assert client_for(populated(), MEMBER).get(
        "/api/v1/admin/catalogue/variants/block").status_code == 403
