"""One uploaded report, read and stored.

Shaped on `app/score_worker/handlers.py`: deterministic, and it never raises. A
poisoned job must not take the worker down, because the next job in the lane
belongs to somebody else.

Two things here are substance rather than shape.

**Rows land as `extracted`.** Nothing written here may reach a score until the
user has been through the confirmation screen. The status is the gate and this
worker never sets anything further along.

**Escalation fires here**, before the user has confirmed anything and
independent of review state. A critical value cannot wait for someone to get
round to a screen, let alone for a clinician queue.

**The scope on the upload read is load bearing.** This process holds
service-role credentials and bypasses RLS by design, so a job naming another
user's upload is refused by this code or by nothing at all.
"""

from typing import Any

from app.common.documents import DocumentNotFound, PathNotOwned, fetch_document
from app.common.logging_config import get_logger, log_context
from app.extraction.escalation import critical_findings
from app.extraction.ingest import VerbatimCheckFailed, extract_report
from app.extraction.ocr import OcrUnavailable, document_from_images, rasterise_pdf
from app.extraction.pdf_text import (
    NATIVE,
    NONE,
    OCR,
    Document,
    Page,
    PasswordRequired,
    UnreadablePdf,
    read_pdf,
)

logger = get_logger(__name__)

UPLOADED = "uploaded"
EXTRACTING = "extracting"
EXTRACTED = "extracted"
NEEDS_PASSWORD = "needs_password"
FAILED = "failed"

NO_TEXT_LAYER = (
    "This looks like a scan or a photograph rather than a PDF with readable "
    "text, so we could not read it yet."
)

OCR_FAILED = (
    "We could not read the text in this photograph. A straighter, brighter "
    "photo of the whole page usually works."
)


class NoOcrEngine(Exception):
    """The report needs OCR and this build has no engine.

    Its own type so the worker can give the user the "looks like a scan"
    message, which is true and actionable, rather than a generic failure.
    """


def _load_upload(supabase, upload_id: str, user_id: str) -> dict | None:
    rows = (
        supabase.table("lab_uploads")
        .select("*")
        .eq("id", upload_id)
        .eq("user_id", user_id)  # the isolation boundary, not an optimisation
        .execute()
        .data
    )
    return rows[0] if rows else None


def _set_status(supabase, upload_id: str, **fields) -> None:
    supabase.table("lab_uploads").update(fields).eq("id", upload_id).execute()


def _load_document(supabase, upload: dict, user_id: str, engine=None) -> Document:
    """Every file of the report, as one document with pages numbered across it.

    A photographed three-page panel is three objects and one report, so page 0
    of the second file is page 1 of the report — which is what `page` on a
    result row has to mean for "from page 2" to be true.

    Three kinds of file arrive and all three end up in the same shape:

      * a PDF with a text layer, read directly — exact, and the only case where
        the verbatim check proves the number is on the paper
      * a PDF without one, which is a picture of paper wrapped in a PDF, so it
        is rasterised and read by the OCR engine
      * a photograph, read by the OCR engine

    With no engine configured the last two cannot be read, and the caller fails
    the upload with a reason rather than storing a guess.
    """
    files = (
        supabase.table("lab_upload_files")
        .select("storage_path,page_index,kind")
        .eq("upload_id", upload["id"])
        .order("page_index")
        .execute()
        .data
    )
    if not files:
        raise DocumentNotFound("the upload has no files")

    pages: list = []
    for_ocr: list[bytes] = []
    for entry in files:
        data = fetch_document(
            supabase,
            user_id=user_id,
            provider=upload.get("storage_provider") or "supabase",
            path=entry["storage_path"],
        )
        if entry.get("kind") == "image":
            for_ocr.append(data)
            continue

        document = read_pdf(data)
        if document.text_layer == NONE:
            # A scan. Needs the same treatment as a photograph.
            for_ocr.extend(rasterise_pdf(data))
            continue
        pages.extend(document.pages)

    # Read last, so a report that mixes a text-layer PDF with photographs keeps
    # the exact pages exact and only the pictures go through OCR.
    ocr_pages: list = []
    if for_ocr:
        if engine is None:
            raise NoOcrEngine(NO_TEXT_LAYER)
        read = document_from_images(for_ocr, engine)
        if read.text_layer == NONE:
            # The engine ran and found no words: a blank, dark or hopelessly
            # skewed photograph. That is a failure the user can fix, and it must
            # not present as a report that happens to contain nothing.
            raise OcrUnavailable("no text was found in the image")
        ocr_pages = list(read.pages)

    combined = pages + ocr_pages
    if not combined:
        return Document(pages=(), text_layer=NONE)

    renumbered = tuple(
        Page(
            index=index,
            words=page.words,
            text=page.text,
            width=page.width,
            height=page.height,
        )
        for index, page in enumerate(combined)
    )
    # Any OCR at all marks the whole report, because the confirmation screen has
    # to treat it with the same care either way and the user is looking at one
    # document, not a mixture.
    return Document(pages=renumbered, text_layer=OCR if ocr_pages else NATIVE)


def _persist(supabase, upload: dict, user_id: str, report) -> None:
    for result in report.results:
        supabase.table("biomarker_results").insert({
            "user_id": user_id,
            "upload_id": upload["id"],
            "biomarker_id": result.biomarker_id,
            "context": result.context,
            "result_type": result.result_type,
            "operator": result.operator,
            "raw_value": result.raw_value,
            "raw_unit": result.raw_unit,
            "value_canonical": result.value_canonical,
            "value_text": result.value_text,
            "unit_canonical": result.unit_canonical,
            "collected_at": report.collected_at.isoformat() if report.collected_at else None,
            "lab_name": report.lab_name,
            "confidence": result.confidence,
            "page": result.page,
            "bbox": result.bbox,
            "status": "extracted",  # never anything further along
            "catalog_version": result.catalog_version,
            "extraction_version": report.extraction_version,
        }).execute()

    for finding in critical_findings(report.results):
        supabase.table("lab_escalations").insert({
            "user_id": user_id,
            "upload_id": upload["id"],
            "biomarker_id": finding.biomarker_id,
            "context": finding.context,
            "value_canonical": finding.value_canonical,
            "operator": finding.operator,
            "unit": finding.unit,
            "severity": finding.severity,
            "message": finding.message,
        }).execute()


def process_lab_job(job: dict, supabase: Any, engine=None, llm=None) -> None:
    """One job. Never raises.

    `engine` and `llm` are both resolved once at startup and passed in rather
    than read from settings here: a handler that reaches for configuration per
    job cannot be tested without an environment, and both are process-level
    facts.

    Both are optional and both default to off. Without an engine, photographs
    and scans fail with a reason. Without a model, label mapping is the
    catalog's alias table alone.
    """
    upload_id = job.get("upload_id")
    user_id = job.get("user_id")
    context = log_context(user_id=user_id)

    if not upload_id or not user_id:
        logger.warning(f"skipping malformed lab job {job!r}")
        return

    upload = _load_upload(supabase, upload_id, user_id)
    if upload is None:
        # Either it is gone, or it belongs to someone else. Both are silence.
        logger.info(f"no upload {upload_id} for this caller {context}")
        return

    if upload.get("status") != UPLOADED:
        # Supabase retries webhooks; a report already in flight or finished must
        # not be read twice, or every value on it doubles.
        logger.info(f"upload {upload_id} is {upload.get('status')}, leaving it {context}")
        return

    _set_status(supabase, upload_id, status=EXTRACTING)

    try:
        document = _load_document(supabase, upload, user_id, engine=engine)
    except PasswordRequired:
        logger.info(f"upload {upload_id} needs a password {context}")
        _set_status(supabase, upload_id, status=NEEDS_PASSWORD)
        return
    except NoOcrEngine:
        # Not a crash and not the user's fault: this build cannot read pictures.
        logger.info(f"upload {upload_id} needs OCR and none is configured {context}")
        _set_status(supabase, upload_id, status=FAILED, text_layer=NONE, error=NO_TEXT_LAYER)
        return
    except OcrUnavailable as error:
        logger.warning(f"upload {upload_id} OCR failed: {error} {context}")
        _set_status(supabase, upload_id, status=FAILED, text_layer=NONE, error=OCR_FAILED)
        return
    except (DocumentNotFound, PathNotOwned, UnreadablePdf) as error:
        logger.warning(f"upload {upload_id} could not be read: {error} {context}")
        _set_status(supabase, upload_id, status=FAILED, error=str(error))
        return
    except Exception:
        logger.exception(f"upload {upload_id} failed while loading {context}")
        _set_status(supabase, upload_id, status=FAILED, error="could not read the document")
        return

    if document.text_layer == NONE:
        # The OCR seam. Not a crash and not the user's fault.
        logger.info(f"upload {upload_id} has no text layer {context}")
        _set_status(
            supabase, upload_id, status=FAILED, text_layer=NONE, error=NO_TEXT_LAYER
        )
        return

    try:
        report = extract_report(document, llm=llm)
    except VerbatimCheckFailed as error:
        # Loud, and nothing is stored. Something produced a value instead of
        # reading one, and a row written now would defeat the whole design.
        logger.error(f"upload {upload_id} failed the verbatim check: {error} {context}")
        _set_status(supabase, upload_id, status=FAILED, error=str(error))
        return
    except Exception:
        logger.exception(f"upload {upload_id} failed during extraction {context}")
        _set_status(supabase, upload_id, status=FAILED, error="could not extract this report")
        return

    try:
        _persist(supabase, upload, user_id, report)
    except Exception:
        logger.exception(f"upload {upload_id} failed while storing {context}")
        _set_status(supabase, upload_id, status=FAILED, error="could not store the results")
        return

    _set_status(
        supabase,
        upload_id,
        status=EXTRACTED,
        collected_at=report.collected_at.isoformat() if report.collected_at else None,
        collected_at_source=report.collected_at_source,
        reported_at=report.reported_at.isoformat() if report.reported_at else None,
        patient_name=report.patient_name,
        lab_name=report.lab_name,
        page_count=report.page_count,
        is_history=report.is_history,
        text_layer=report.text_layer,
        extraction_version=report.extraction_version,
        error=None,
    )
    logger.info(
        f"upload {upload_id} extracted: {len(report.results)} result(s), "
        f"{len(report.skipped)} skipped {context}"
    )
