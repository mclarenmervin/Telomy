"""The worker that reads an uploaded report.

Same shape as the score worker: dequeue, do deterministic work, never raise. A
poisoned job must not take the worker down, because the next job in the lane
belongs to somebody else.

Two things here are not shape, they are substance:

**Rows land as `extracted`, never `confirmed`.** Nothing the worker writes may
reach a score until the user has been through it.

**Escalation fires here**, before confirmation and independent of review state.
A critical value cannot wait for the user to get round to the confirmation
screen, let alone for a clinician queue.
"""

from app.extraction_worker.handlers import process_lab_job
from tests.fakes import FakeSupabase
from tests.lab_fixtures import lab_report_pdf

USER = "c3c4eefd-b60c-438e-8cdc-0f3f0fde7617"
OTHER = "0d6d0ca2-1d3e-4a1f-9b77-2f0d7a4c9e11"
UPLOAD = "11111111-1111-4111-8111-111111111111"
PREFIX = f"{USER}/2026/{UPLOAD}/"
PATH = f"{PREFIX}0.pdf"


def make_db(status="uploaded", user_id=USER, path=PATH, pdf=None, rows=None):
    return FakeSupabase(
        tables={
            "lab_uploads": [{
                "id": UPLOAD, "user_id": user_id, "status": status,
                "storage_provider": "supabase", "storage_prefix": PREFIX,
                "content_sha256": "sha-1",
            }],
            "lab_upload_files": [{
                "id": "f1", "upload_id": UPLOAD, "storage_path": path,
                "content_sha256": "file-a", "page_index": 0, "kind": "pdf",
            }],
            "biomarker_results": [],
            "lab_escalations": [],
        },
        objects={path: pdf if pdf is not None else lab_report_pdf(rows=rows)},
    )


def upload_row(db):
    return db.tables["lab_uploads"][0]


def job(user_id=USER):
    return {"upload_id": UPLOAD, "user_id": user_id}


# ── The happy path ───────────────────────────────────────────────────────────

def test_a_report_becomes_rows():
    db = make_db()

    process_lab_job(job(), db)

    markers = {r["biomarker_id"] for r in db.tables["biomarker_results"]}
    assert {"glucose_fasting", "hba1c", "haemoglobin", "ferritin"} <= markers


def test_rows_land_as_extracted_and_never_as_confirmed():
    """The gate between extraction and anything a score reads."""
    db = make_db()

    process_lab_job(job(), db)

    assert {r["status"] for r in db.tables["biomarker_results"]} == {"extracted"}


def test_the_upload_is_marked_extracted_and_carries_what_was_read():
    db = make_db()

    process_lab_job(job(), db)

    row = upload_row(db)
    assert row["status"] == "extracted"
    assert row["collected_at"].startswith("2026-09-28")
    assert "SUNITA" in row["patient_name"]
    assert row["text_layer"] == "native"
    assert row["page_count"] == 1


def test_rows_carry_their_provenance():
    db = make_db()

    process_lab_job(job(), db)

    row = next(r for r in db.tables["biomarker_results"] if r["biomarker_id"] == "hba1c")
    assert row["page"] == 0
    # The page extent travels with the box: coordinates are points for a PDF
    # and pixels for an OCR'd image, so the box alone cannot be placed, and
    # placing it is what shows the user the crop their number came from.
    assert set(row["bbox"]) == {
        "x0", "x1", "top", "bottom", "page_width", "page_height"
    }
    assert row["raw_value"] == "7.8"
    assert row["upload_id"] == UPLOAD


def test_the_same_marker_in_two_contexts_becomes_two_rows():
    db = make_db()

    process_lab_job(job(), db)

    glucose = [r for r in db.tables["biomarker_results"]
               if r["biomarker_id"] == "glucose_fasting"]
    assert {r["context"] for r in glucose} == {"fasting", "post_prandial"}


def test_a_qualitative_result_is_stored_as_text():
    db = make_db(rows=[("Ferritin", "Not detected", "", "")])

    process_lab_job(job(), db)

    row = db.tables["biomarker_results"][0]
    assert row["result_type"] == "qualitative"
    assert row["value_text"] == "Not detected"
    assert row["value_canonical"] is None


def test_a_qualitative_result_never_escalates():
    """Escalation compares a number against critical bounds. Text has none, and
    inventing one to compare would be the exact coercion the schema forbids."""
    db = make_db(rows=[("Ferritin", "Not detected", "", "")])

    process_lab_job(job(), db)

    assert db.tables["lab_escalations"] == []


# ── Escalation ───────────────────────────────────────────────────────────────

def test_a_critical_value_escalates_before_anyone_confirms_anything():
    db = make_db(rows=[("Haemoglobin", "4.1", "g/dL", "13.0 - 17.0")])

    process_lab_job(job(), db)

    assert len(db.tables["lab_escalations"]) == 1
    assert db.tables["lab_escalations"][0]["biomarker_id"] == "haemoglobin"
    # And the result it came from is still merely extracted.
    assert db.tables["biomarker_results"][0]["status"] == "extracted"


def test_a_normal_panel_escalates_nothing():
    db = make_db(rows=[
        ("Haemoglobin", "13.2", "g/dL", "13.0 - 17.0"),
        ("Ferritin", "60", "ng/mL", "22 - 322"),
        ("HbA1c", "5.4", "%", "4.0 - 5.6"),
    ])

    process_lab_job(job(), db)

    assert db.tables["lab_escalations"] == []


def test_a_severely_deficient_vitamin_d_escalates_under_the_current_bounds():
    """Documenting a live behaviour rather than endorsing it.

    The default fixture's `<3.0 ng/mL` is below vitamin D's critical floor of
    5.0, so it escalates with the same wording and the same single severity
    level as a haemoglobin of 4.1. Those are not equally urgent.

    One severity level is the right amount of machinery for F3, and the message
    says "promptly" rather than anything stronger. But whether 5.0 is the
    threshold at which we interrupt someone's day is a clinical judgement, and
    biomarkers.v1.yaml has not been reviewed yet. This test exists so the
    behaviour is visible when that review happens.
    """
    db = make_db()

    process_lab_job(job(), db)

    escalated = {e["biomarker_id"] for e in db.tables["lab_escalations"]}
    assert escalated == {"vitamin_d_25oh"}


# ── Idempotence ──────────────────────────────────────────────────────────────

def test_a_row_already_past_uploaded_is_left_alone():
    """Supabase retries webhooks. A second worker picking up a report already in
    flight would double every value on it."""
    db = make_db(status="extracting")

    process_lab_job(job(), db)

    assert db.tables["biomarker_results"] == []


def test_a_confirmed_report_is_never_re_extracted():
    db = make_db(status="confirmed")

    process_lab_job(job(), db)

    assert db.tables["biomarker_results"] == []


# ── Tenant isolation ─────────────────────────────────────────────────────────

def test_a_job_naming_another_users_upload_does_nothing():
    """The worker holds service-role credentials and bypasses RLS, so the scope
    on this read is the only thing between one user's report and another's."""
    db = make_db(user_id=OTHER)

    process_lab_job(job(user_id=USER), db)

    assert db.tables["biomarker_results"] == []
    assert upload_row(db)["status"] == "uploaded"


# ── Failures ─────────────────────────────────────────────────────────────────

def test_a_password_protected_report_asks_rather_than_failing():
    db = make_db(pdf=lab_report_pdf(password="01011972"))

    process_lab_job(job(), db)

    assert upload_row(db)["status"] == "needs_password"


def test_a_scan_with_no_text_layer_fails_with_a_reason_naming_the_cause():
    from tests.lab_fixtures import image_only_pdf

    db = make_db(pdf=image_only_pdf())

    process_lab_job(job(), db)

    row = upload_row(db)
    assert row["status"] == "failed"
    assert "text" in row["error"].lower() or "scan" in row["error"].lower()
    assert row["text_layer"] == "none"


def test_a_missing_object_fails_the_upload_rather_than_the_worker():
    db = make_db()
    db.storage.objects.clear()

    process_lab_job(job(), db)

    assert upload_row(db)["status"] == "failed"


def test_a_corrupt_file_fails_the_upload():
    db = make_db(pdf=b"this is not a pdf")

    process_lab_job(job(), db)

    assert upload_row(db)["status"] == "failed"


# ── The label-mapping model ──────────────────────────────────────────────────

def test_a_label_the_catalog_cannot_place_is_skipped_without_a_model():
    """The alias table is the product, not a cache in front of a model: with no
    key configured a full panel still extracts, and an unknown marker is simply
    left out rather than guessed."""
    db = make_db(rows=[
        ("HbA1c", "7.8", "%", "4.0 - 5.6"),
        ("Serum Fredholm Index", "12", "ng/mL", "5 - 20"),
    ])

    process_lab_job(job(), db, llm=None)

    assert [r["biomarker_id"] for r in db.tables["biomarker_results"]] == ["hba1c"]


def test_the_model_places_a_label_the_catalog_cannot():
    """The second tier, reachable in production only because the worker passes
    the model in. Without that wiring it was dead code."""
    import json

    class FakeLLM:
        def __init__(self):
            self.seen = []

        def invoke(self, messages):
            self.seen.append(" ".join(str(p) for pair in messages for p in pair))

            class Response:
                content = json.dumps({"Serum Fredholm Index": "ferritin"})

            return Response()

    llm = FakeLLM()
    # A deliberately distinctive value. "12" would have collided with
    # `vitamin_b12` in the catalog listing the prompt carries, and the
    # assertion below would have failed on a property that actually holds.
    db = make_db(rows=[("Serum Fredholm Index", "873.4", "ng/mL", "5 - 20")])

    process_lab_job(job(), db, llm=llm)

    assert [r["biomarker_id"] for r in db.tables["biomarker_results"]] == ["ferritin"]
    # P2 holds through the wiring too: the model saw the label, never the value.
    assert "873.4" not in " ".join(llm.seen)


# ── Photographs and scans ────────────────────────────────────────────────────

def image_db(pdf=None, kind="image", path=f"{PREFIX}0.jpg"):
    db = make_db(path=path, pdf=pdf if pdf is not None else b"jpeg-bytes")
    db.tables["lab_upload_files"][0]["kind"] = kind
    db.tables["lab_upload_files"][0]["storage_path"] = path
    return db


def panel_engine():
    """An engine that reads a one-row results table, laid out like a real one."""
    from app.extraction.pdf_text import Word

    class Engine:
        name = "fake"

        def read_image(self, data):
            rows = [
                ("TEST", 50), ("RESULT", 250), ("UNIT", 330), ("BIOLOGICAL", 410),
                ("HbA1c", 50), ("7.8", 250), ("%", 330), ("4.0", 410),
                ("Collected", 50), ("On", 105), (":", 125), ("28/09/2026", 140),
            ]
            return [
                Word(text=text, x0=x, x1=x + 40,
                     top=100 + (index // 4) * 20, bottom=110 + (index // 4) * 20)
                for index, (text, x) in enumerate(rows)
            ]

    return Engine()


def test_a_photograph_fails_with_a_reason_when_no_engine_is_configured():
    """The honest state of F3a. Not a crash, and not the user's fault."""
    db = image_db()

    process_lab_job(job(), db, engine=None)

    row = upload_row(db)
    assert row["status"] == "failed"
    assert "photograph" in row["error"] or "scan" in row["error"]
    assert row["text_layer"] == "none"


def test_a_photograph_is_read_when_an_engine_is_configured():
    db = image_db()

    process_lab_job(job(), db, engine=panel_engine())

    assert upload_row(db)["status"] == "extracted"
    assert [r["biomarker_id"] for r in db.tables["biomarker_results"]] == ["hba1c"]


def test_a_photographed_report_is_recorded_as_ocr_derived():
    """It changes how much the result is worth trusting, and the confirmation
    screen needs to know to show the crop."""
    db = image_db()

    process_lab_job(job(), db, engine=panel_engine())

    assert upload_row(db)["text_layer"] == "ocr"


def test_an_ocr_result_carries_lower_confidence_than_a_text_layer_one():
    """The verbatim check against OCR output proves the number is in the OCR's
    reading of the page, not that it is on the paper."""
    from_ocr = image_db()
    process_lab_job(job(), from_ocr, engine=panel_engine())

    from_text = make_db()
    process_lab_job(job(), from_text, engine=None)

    ocr_row = next(r for r in from_ocr.tables["biomarker_results"]
                   if r["biomarker_id"] == "hba1c")
    text_row = next(r for r in from_text.tables["biomarker_results"]
                    if r["biomarker_id"] == "hba1c")
    assert ocr_row["confidence"] < text_row["confidence"]


def test_a_scanned_pdf_is_rasterised_and_read():
    """A scan is a picture of paper wrapped in a PDF, so it gets the same
    treatment as a photograph rather than being refused."""
    from tests.lab_fixtures import image_only_pdf

    db = make_db(pdf=image_only_pdf())

    process_lab_job(job(), db, engine=panel_engine())

    assert upload_row(db)["status"] == "extracted"
    assert upload_row(db)["text_layer"] == "ocr"


def test_a_text_layer_pdf_never_goes_near_the_engine():
    """Reading exact text through OCR would throw away the one case where the
    verbatim check proves the number is on the paper."""
    calls = []

    class Counting:
        name = "counting"

        def read_image(self, data):
            calls.append(data)
            return []

    db = make_db()
    process_lab_job(job(), db, engine=Counting())

    assert calls == []
    assert upload_row(db)["text_layer"] == "native"


def test_an_engine_that_cannot_read_the_image_fails_with_advice():
    class Broken:
        name = "broken"

        def read_image(self, data):
            raise RuntimeError("model weights are missing")

    db = image_db()

    process_lab_job(job(), db, engine=Broken())

    row = upload_row(db)
    assert row["status"] == "failed"
    assert "photo" in row["error"].lower()


def test_a_blank_photograph_is_a_failure_not_an_empty_report():
    """Zero values read must not look like a report that happens to have none."""
    class Blank:
        name = "blank"

        def read_image(self, data):
            return []

    db = image_db()

    process_lab_job(job(), db, engine=Blank())

    assert upload_row(db)["status"] == "failed"
    assert db.tables["biomarker_results"] == []


def test_a_malformed_job_is_ignored_without_raising():
    db = make_db()

    process_lab_job({"upload_id": None}, db)
    process_lab_job({}, db)

    assert db.tables["biomarker_results"] == []


def test_an_upload_that_does_not_exist_is_ignored():
    db = make_db()

    process_lab_job({"upload_id": "nope", "user_id": USER}, db)

    assert db.tables["biomarker_results"] == []
