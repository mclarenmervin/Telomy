"""Reconciling uploads that never finished.

Two kinds of stuck, both routine rather than exceptional:

**Stalled.** A worker killed mid-report leaves the row in `extracting` forever.
The status guard that stops a webhook retry re-extracting also stops anything
ever picking it up again, so the user watches a spinner that will never resolve.

**Orphaned.** The phone writes to Storage and then inserts the row. A crash
between the two leaves a report with no file to read, sitting at `uploaded`
waiting for a webhook that has already fired.

The decisions live in `plan.py` as pure functions over rows. This module is only
the part that touches the database, so the cadence and the rules stay testable
without one.
"""

from datetime import datetime
from typing import Any

from app.common.logging_config import get_logger
from app.scheduler.plan import (
    NO_FILES_REASON,
    STALLED_REASON,
    orphaned_upload_ids,
    stalled_upload_ids,
)

logger = get_logger(__name__)

FAILED = "failed"

# Enough to cover anything genuinely in flight without scanning the table.
_SWEEP_LIMIT = 500


def _fail(supabase, upload_ids, reason: str) -> int:
    for upload_id in upload_ids:
        supabase.table("lab_uploads").update(
            {"status": FAILED, "error": reason}
        ).eq("id", upload_id).execute()
    return len(upload_ids)


def sweep_uploads(supabase: Any, now: datetime | None = None) -> dict:
    """Mark stuck uploads failed. Returns what it did, for the log.

    Never raises: a reconciliation sweep that dies takes the whole scheduler
    tick with it, and that stops every scheduled thing in the product.
    """
    try:
        uploads = (
            supabase.table("lab_uploads")
            .select("id,status,created_at,updated_at")
            .in_("status", ["uploaded", "extracting"])
            .range(0, _SWEEP_LIMIT - 1)
            .execute()
            .data
        )
    except Exception:
        logger.exception("lab sweep could not read uploads")
        return {"stalled": 0, "orphaned": 0}

    if not uploads:
        return {"stalled": 0, "orphaned": 0}

    try:
        files = (
            supabase.table("lab_upload_files")
            .select("upload_id")
            .in_("upload_id", [u["id"] for u in uploads])
            .execute()
            .data
        )
    except Exception:
        logger.exception("lab sweep could not read upload files")
        files = None

    stalled = _fail(supabase, stalled_upload_ids(uploads, now), STALLED_REASON)
    # Only when the file read succeeded. Treating a failed query as "no files"
    # would fail every upload in flight.
    orphaned = 0
    if files is not None:
        orphaned = _fail(
            supabase,
            orphaned_upload_ids(uploads, [f["upload_id"] for f in files]),
            NO_FILES_REASON,
        )

    if stalled or orphaned:
        logger.info(f"lab sweep: {stalled} stalled, {orphaned} orphaned marked failed")
    return {"stalled": stalled, "orphaned": orphaned}
