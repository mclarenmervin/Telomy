"""One uploaded genetics export, read and reduced to the four rows we keep.

The sibling of `handlers.py`, same shape: deterministic, and it never raises,
because a poisoned job must not take the worker down when the next job in the
lane belongs to somebody else.

Three things here are substance rather than shape.

**The allowlist is applied inside `genetics.import_raw`**, between parsing and
returning, so nothing in this file is in a position to widen it. What reaches
the database is whatever that function handed back, and the discarded rows are
never written anywhere -- not to a staging table, not to a log line, not even
to the failure reason.

**Only counts are recorded.** `rows_read` and `rows_kept` go on the upload
row. "We read 612,431 rows and kept 3" is useful to a person; which of the
other 612,428 were interesting is the thing this product refuses to say, and
there is no column anywhere it could go.

**The scope on the upload read is load bearing.** This process holds
service-role credentials and bypasses RLS by design, so a job naming another
user's upload is refused by this code or by nothing at all.
"""

from typing import Any

from app.analytics import variant_catalog
from app.analytics.genetics import UnreadableGeneticFile, import_raw
from app.common.documents import GENETICS_BUCKET, DocumentNotFound, PathNotOwned, fetch_document
from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)

#: The job kind this handler answers to. Declared by the consumer and
#: imported by the gateway that produces it, the same direction
#: `DRAFT_JOB_KIND` and `SCORE_RECOMPUTE` already run in -- a worker that
#: imported the gateway would make the queue a two-way dependency.
GENETICS_JOB_KIND = "genetics"

UPLOADED = "uploaded"
IMPORTED = "imported"
UNREADABLE = "unreadable"
FAILED = "failed"


def _load_upload(supabase, upload_id: str, user_id: str) -> dict | None:
    rows = (
        supabase.table("genetic_uploads")
        .select("id,user_id,status,storage_provider,storage_path")
        .eq("id", upload_id)
        .eq("user_id", user_id)
        .execute()
        .data
    )
    return rows[0] if rows else None


def _finish(supabase, upload_id: str, **fields) -> None:
    supabase.table("genetic_uploads").update(fields).eq("id", upload_id).execute()


def _store(supabase, user_id: str, upload_id: str, calls, version: str) -> None:
    """Upsert the kept calls.

    Upsert rather than insert, on `(user_id, rsid)`: a second export of the
    same person is the same person, and two genotypes for one locus is a
    contradiction the table refuses. The newer file wins, because re-importing
    is what somebody does when the first file was wrong.
    """
    if not calls:
        return
    supabase.table("genetic_variants").upsert(
        [
            {
                "user_id": user_id,
                "rsid": call.rsid,
                "genotype": call.genotype,
                "upload_id": upload_id,
                "variants_version": version,
            }
            for call in calls
        ],
        on_conflict="user_id,rsid",
    ).execute()


def process_genetics_job(job: dict, supabase: Any) -> None:
    """One job. Never raises."""
    upload_id = job.get("upload_id")
    user_id = job.get("user_id")
    context = log_context(user_id=user_id)

    if not upload_id or not user_id:
        logger.warning(f"skipping malformed genetics job {job!r}")
        return

    upload = _load_upload(supabase, upload_id, user_id)
    if upload is None:
        # Either it is gone, or it belongs to someone else. Both are silence.
        logger.info(f"no genetic upload {upload_id} for this caller {context}")
        return

    if upload.get("status") != UPLOADED:
        # Supabase retries webhooks. Re-importing is harmless to the table,
        # whose unique constraint absorbs it, and is still a second download
        # of somebody's genome.
        logger.info(
            f"genetic upload {upload_id} is {upload.get('status')}, leaving it {context}"
        )
        return

    try:
        raw = fetch_document(
            supabase,
            user_id=user_id,
            provider=upload.get("storage_provider") or "supabase",
            path=upload["storage_path"],
            bucket=GENETICS_BUCKET,
        )
    except (DocumentNotFound, PathNotOwned) as error:
        logger.warning(f"genetic upload {upload_id} has no readable object: {error} {context}")
        _finish(supabase, upload_id, status=FAILED,
                failure_reason="we could not open the file you uploaded")
        return
    except Exception:
        logger.exception(f"fetching genetic upload {upload_id} failed {context}")
        _finish(supabase, upload_id, status=FAILED,
                failure_reason="something went wrong on our side reading the file")
        return

    try:
        text = raw.decode("utf-8", errors="replace")
        result = import_raw(text)
    except UnreadableGeneticFile as error:
        # Terminal and different from `failed`: there is nothing to retry, and
        # the user needs to be told to upload a different file rather than to
        # wait. The reason never names a locus, because the file we could not
        # read is still the file we are refusing to describe.
        logger.info(f"genetic upload {upload_id} is not a format we read {context}")
        _finish(supabase, upload_id, status=UNREADABLE, failure_reason=str(error))
        return
    except Exception:
        logger.exception(f"parsing genetic upload {upload_id} failed {context}")
        _finish(supabase, upload_id, status=FAILED,
                failure_reason="something went wrong on our side reading the file")
        return

    try:
        _store(supabase, user_id, upload_id, result.calls, variant_catalog.variants_version())
    except Exception:
        logger.exception(f"storing variants for {upload_id} failed {context}")
        _finish(supabase, upload_id, status=FAILED,
                failure_reason="something went wrong on our side saving the result")
        return

    _finish(
        supabase,
        upload_id,
        status=IMPORTED,
        source_format=result.format,
        rows_read=result.read,
        rows_kept=len(result.calls),
        imported_at="now()",
    )
    # Counts only. A log line naming a refused locus would put in the logs
    # exactly what the allowlist keeps out of the database.
    logger.info(
        f"genetic upload {upload_id} imported {context} format={result.format} "
        f"read={result.read} kept={len(result.calls)} conflicts={result.conflicts}"
    )
