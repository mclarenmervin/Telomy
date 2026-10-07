"""The confirmation surface.

Confirmation is not a formality. It is the only path on which four things
happen, and the reason 007 removed the phone's ability to set `status` itself:

  * the patient-name check, because the report may be someone else's
  * the collection date, captured when we could not read one confidently
  * the projection into `health_measurements` **with origin='server'**, without
    which the phone's next sync deletes it days later
  * the score recompute, queued rather than run inline

The caller comes from the verified token throughout. There is no `user_id` in
any path, query or body here.
"""

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.common.supabase_client import get_supabase_client
from app.gateway.api.labs import router
from app.gateway.auth import current_user_id
from app.gateway.queue_provider import get_score_queue
from tests.fakes import FakeSupabase

ALICE = "00000000-0000-0000-0000-00000000000a"
BOB = "00000000-0000-0000-0000-00000000000b"
UPLOAD = "11111111-1111-4111-8111-111111111111"


class SpyQueue:
    def __init__(self):
        self.jobs = []

    def enqueue(self, job):
        self.jobs.append(job)


def make_db(
    user_id=ALICE,
    status="extracted",
    collected_at="2026-09-28T07:30:00+00:00",
    collected_at_source="extracted",
    patient_name="MRS SUNITA R PATNAIK",
    results=None,
):
    default = [
        {"id": "r1", "user_id": user_id, "upload_id": UPLOAD,
         "biomarker_id": "hba1c", "context": "standard", "result_type": "quantitative",
         "operator": "=", "raw_value": "7.8", "raw_unit": "%", "value_canonical": 7.8,
         "unit_canonical": "%", "status": "extracted", "page": 0,
         "collected_at": collected_at},
        {"id": "r2", "user_id": user_id, "upload_id": UPLOAD,
         "biomarker_id": "vitamin_d_25oh", "context": "standard",
         "result_type": "quantitative", "operator": "<", "raw_value": "3.0",
         "raw_unit": "ng/mL", "value_canonical": 3.0, "unit_canonical": "ng/mL",
         "status": "extracted", "page": 0, "collected_at": collected_at},
    ]
    return FakeSupabase({
        "lab_uploads": [{
            "id": UPLOAD, "user_id": user_id, "status": status,
            "storage_provider": "supabase", "storage_prefix": f"{user_id}/2026/{UPLOAD}/",
            "collected_at": collected_at, "collected_at_source": collected_at_source,
            "patient_name": patient_name, "lab_name": "Dr Lal PathLabs",
            "is_history": False, "created_at": "2026-10-01T09:00:00+00:00",
        }],
        "biomarker_results": results if results is not None else default,
        "health_measurements": [],
    })


def client_for(db, user_id=ALICE):
    app = FastAPI()
    app.include_router(router)
    queue = SpyQueue()
    app.dependency_overrides[current_user_id] = lambda: user_id
    app.dependency_overrides[get_supabase_client] = lambda: db
    app.dependency_overrides[get_score_queue] = lambda: queue
    return TestClient(app), queue


def confirm_body(**overrides):
    body = {
        "patient_is_me": True,
        "decisions": [
            {"result_id": "r1", "action": "confirm"},
            {"result_id": "r2", "action": "confirm"},
        ],
    }
    body.update(overrides)
    return body


# ── Reading ──────────────────────────────────────────────────────────────────

def test_a_user_sees_their_own_uploads():
    client, _ = client_for(make_db())

    response = client.get("/api/v1/labs/uploads")

    assert response.status_code == 200
    assert [u["id"] for u in response.json()] == [UPLOAD]


def test_a_user_does_not_see_another_users_uploads():
    client, _ = client_for(make_db(user_id=BOB), user_id=ALICE)

    assert client.get("/api/v1/labs/uploads").json() == []


def test_the_results_of_an_upload_come_back_for_review():
    client, _ = client_for(make_db())

    body = client.get(f"/api/v1/labs/uploads/{UPLOAD}").json()

    assert body["upload"]["lab_name"] == "Dr Lal PathLabs"
    assert {r["biomarker_id"] for r in body["results"]} == {"hba1c", "vitamin_d_25oh"}


def test_another_users_upload_is_not_readable():
    client, _ = client_for(make_db(user_id=BOB), user_id=ALICE)

    assert client.get(f"/api/v1/labs/uploads/{UPLOAD}").status_code == 404


def test_the_response_carries_a_url_per_page_of_the_report():
    """So the screen can show the user the crop each number came from. With OCR
    that is the check that replaces the verbatim one, because comparing our
    number against their memory is worthless and against the picture is not."""
    db = make_db()
    db.tables["lab_upload_files"] = [
        {"upload_id": UPLOAD, "storage_path": f"{ALICE}/2026/{UPLOAD}/0.pdf",
         "page_index": 0, "kind": "pdf"},
    ]
    db.storage.objects[f"{ALICE}/2026/{UPLOAD}/0.pdf"] = b"%PDF the report"
    client, _ = client_for(db)

    pages = client.get(f"/api/v1/labs/uploads/{UPLOAD}").json()["pages"]

    assert len(pages) == 1
    assert pages[0]["page_index"] == 0
    assert pages[0]["url"].startswith("https://")


def test_a_missing_page_image_does_not_break_the_review_screen():
    """The values are still reviewable; they just cannot be shown in context."""
    db = make_db()
    db.tables["lab_upload_files"] = [
        {"upload_id": UPLOAD, "storage_path": f"{ALICE}/2026/{UPLOAD}/0.pdf",
         "page_index": 0, "kind": "pdf"},
    ]
    client, _ = client_for(db)

    body = client.get(f"/api/v1/labs/uploads/{UPLOAD}").json()

    assert body["pages"][0]["url"] is None
    assert len(body["results"]) == 2


def test_another_users_page_image_is_never_signed():
    """The adapter refuses it, and this is the only place a URL is minted."""
    db = make_db()
    db.tables["lab_upload_files"] = [
        {"upload_id": UPLOAD, "storage_path": f"{BOB}/2026/{UPLOAD}/0.pdf",
         "page_index": 0, "kind": "pdf"},
    ]
    db.storage.objects[f"{BOB}/2026/{UPLOAD}/0.pdf"] = b"%PDF not theirs"
    client, _ = client_for(db)

    pages = client.get(f"/api/v1/labs/uploads/{UPLOAD}").json()["pages"]

    assert pages[0]["url"] is None


def test_results_are_presented_ungraded_while_the_catalog_is_unreviewed():
    """The user sees the number as printed and no verdict about it."""
    client, _ = client_for(make_db())

    results = client.get(f"/api/v1/labs/uploads/{UPLOAD}").json()["results"]

    assert {r["grade"] for r in results} == {"ungraded"}


# ── Confirming ───────────────────────────────────────────────────────────────

def test_confirming_marks_the_results_and_the_upload():
    db = make_db()
    client, _ = client_for(db)

    response = client.post(f"/api/v1/labs/uploads/{UPLOAD}/confirm", json=confirm_body())

    assert response.status_code == 200
    assert {r["status"] for r in db.tables["biomarker_results"]} == {"confirmed"}
    assert db.tables["lab_uploads"][0]["status"] == "confirmed"


def test_a_confirmed_result_is_projected_with_server_origin():
    """Without origin='server', save_normalized_wellness deletes this on the
    user's next phone sync -- days later, looking like an extraction bug."""
    db = make_db()
    client, _ = client_for(db)

    client.post(f"/api/v1/labs/uploads/{UPLOAD}/confirm", json=confirm_body())

    projected = db.tables["health_measurements"]
    assert projected, "nothing reached health_measurements"
    assert {m["origin"] for m in projected} == {"server"}
    assert all(m["id"] for m in projected), "the table has no default id"


def test_a_censored_result_is_not_projected():
    """health_measurements has no operator column, so a projected `<3.0` becomes
    indistinguishable from a measured 3.0 and would reach biological age. It
    stays in biomarker_results, where the operator survives."""
    db = make_db()
    client, _ = client_for(db)

    client.post(f"/api/v1/labs/uploads/{UPLOAD}/confirm", json=confirm_body())

    assert {m["measurement_type"] for m in db.tables["health_measurements"]} == {"hba1c"}


def test_confirming_queues_a_recompute_rather_than_running_one():
    """A range change or a bulk upload must never run scoring inline."""
    db = make_db()
    client, queue = client_for(db)

    client.post(f"/api/v1/labs/uploads/{UPLOAD}/confirm", json=confirm_body())

    assert queue.jobs and queue.jobs[0]["user_id"] == ALICE


def test_a_rejected_result_is_marked_and_not_projected():
    db = make_db()
    client, _ = client_for(db)

    client.post(f"/api/v1/labs/uploads/{UPLOAD}/confirm", json=confirm_body(decisions=[
        {"result_id": "r1", "action": "reject"},
        {"result_id": "r2", "action": "confirm"},
    ]))

    statuses = {r["id"]: r["status"] for r in db.tables["biomarker_results"]}
    assert statuses["r1"] == "rejected"
    assert db.tables["health_measurements"] == []


def test_a_corrected_value_is_reconverted_not_taken_at_face_value():
    """The user retypes 7.9 mmol/L. We convert it the same way extraction would,
    rather than storing whatever number arrives in the request."""
    db = make_db()
    client, _ = client_for(db)

    client.post(f"/api/v1/labs/uploads/{UPLOAD}/confirm", json=confirm_body(decisions=[
        {"result_id": "r1", "action": "correct", "value": 6.5, "unit": "%"},
        {"result_id": "r2", "action": "reject"},
    ]))

    row = next(r for r in db.tables["biomarker_results"] if r["id"] == "r1")
    assert row["status"] == "corrected"
    assert row["value_canonical"] == 6.5


def test_a_correction_in_a_unit_we_cannot_convert_is_refused():
    db = make_db()
    client, _ = client_for(db)

    response = client.post(f"/api/v1/labs/uploads/{UPLOAD}/confirm",
                           json=confirm_body(decisions=[
                               {"result_id": "r1", "action": "correct",
                                "value": 6.5, "unit": "furlongs"},
                               {"result_id": "r2", "action": "reject"},
                           ]))

    assert response.status_code == 422
    assert db.tables["lab_uploads"][0]["status"] == "extracted", "nothing was applied"


# ── The patient-name check ───────────────────────────────────────────────────

def test_a_report_naming_someone_else_blocks_ingestion():
    """The document may be a family member's. One phone per household is common
    here, and the whole model assumes one body per account."""
    db = make_db()
    client, _ = client_for(db)

    response = client.post(f"/api/v1/labs/uploads/{UPLOAD}/confirm",
                           json=confirm_body(patient_is_me=False))

    assert response.status_code == 409
    assert db.tables["health_measurements"] == []
    assert db.tables["lab_uploads"][0]["status"] == "extracted"


def test_an_upload_with_no_extracted_name_does_not_demand_confirmation():
    db = make_db(patient_name=None)
    client, _ = client_for(db)

    body = confirm_body()
    body.pop("patient_is_me")
    response = client.post(f"/api/v1/labs/uploads/{UPLOAD}/confirm", json=body)

    assert response.status_code == 200


# ── The collection date ──────────────────────────────────────────────────────

def test_an_unreadable_collection_date_must_be_supplied():
    """Trending uses the collection date. Guessing puts a 2023 panel on today's
    chart, so the UI asks and the endpoint insists."""
    db = make_db(collected_at=None, collected_at_source="unknown")
    client, _ = client_for(db)

    response = client.post(f"/api/v1/labs/uploads/{UPLOAD}/confirm", json=confirm_body())

    assert response.status_code == 422
    assert "collect" in response.json()["detail"].lower()


def test_a_supplied_collection_date_is_recorded_against_every_result():
    db = make_db(collected_at=None, collected_at_source="unknown")
    client, _ = client_for(db)

    response = client.post(
        f"/api/v1/labs/uploads/{UPLOAD}/confirm",
        json=confirm_body(collected_at="2026-09-28T07:30:00+00:00"),
    )

    assert response.status_code == 200
    assert db.tables["lab_uploads"][0]["collected_at_source"] == "user"
    assert all(r["collected_at"].startswith("2026-09-28")
               for r in db.tables["biomarker_results"])


# ── Partial and repeated confirmation ────────────────────────────────────────

def test_every_result_needs_a_decision():
    """A silent partial confirmation would leave rows nobody ever looks at
    again, invisible to scores and invisible to the user."""
    db = make_db()
    client, _ = client_for(db)

    response = client.post(f"/api/v1/labs/uploads/{UPLOAD}/confirm",
                           json=confirm_body(decisions=[
                               {"result_id": "r1", "action": "confirm"},
                           ]))

    assert response.status_code == 422


def test_a_decision_about_another_uploads_result_is_refused():
    db = make_db()
    client, _ = client_for(db)

    response = client.post(f"/api/v1/labs/uploads/{UPLOAD}/confirm",
                           json=confirm_body(decisions=[
                               {"result_id": "r1", "action": "confirm"},
                               {"result_id": "r2", "action": "confirm"},
                               {"result_id": "elsewhere", "action": "confirm"},
                           ]))

    assert response.status_code == 422


def test_an_already_confirmed_upload_is_not_confirmed_twice():
    """Double projection would double every value on the user's chart."""
    db = make_db(status="confirmed")
    client, _ = client_for(db)

    response = client.post(f"/api/v1/labs/uploads/{UPLOAD}/confirm", json=confirm_body())

    assert response.status_code == 409
    assert db.tables["health_measurements"] == []


def test_confirming_another_users_upload_is_a_404():
    db = make_db(user_id=BOB)
    client, _ = client_for(db, user_id=ALICE)

    response = client.post(f"/api/v1/labs/uploads/{UPLOAD}/confirm", json=confirm_body())

    assert response.status_code == 404
    assert db.tables["health_measurements"] == []
