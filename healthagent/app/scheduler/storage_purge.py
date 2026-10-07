"""Reclaiming objects whose owner is gone.

Deleting a `storage.objects` row removes every route to a file but leaves the
bytes in the store behind it, and Postgres cannot reach that store. So account
deletion records the work in `storage_purges` and this sweep finishes it through
the Storage API — the only interface that removes the object as well as the row.

Under DPDP, "deleted" has to mean the bytes are gone. Between the deletion and
this sweep the files are already unreachable, because the policies key on
`auth.uid()` and that account no longer exists. Unreachable is not deleted.

The one outcome worse than a slow purge is a row marked done whose bytes are
still there: it looks compliant and is not. So a failure stays on the queue,
records why, and is retried.
"""

from datetime import datetime, timezone
from typing import Any

from app.common.logging_config import get_logger

logger = get_logger(__name__)

# Per tick. A deleted account is rarely more than a handful of objects, and a
# sweep that tried to drain an unbounded queue would hold the tick open.
_PREFIX_LIMIT = 20

# The Storage API takes a list; sending thousands of paths in one call is how a
# request times out and the whole prefix gets retried for one bad page.
_REMOVE_BATCH = 100


def _validate(prefix: str) -> None:
    """The prefix rule, checked here as well as in SQL.

    A purge is not something to be clever about. An empty prefix matches every
    object in the bucket; one without a trailing slash matches sibling folders
    whose names merely start the same way, so `{uid}/` would take
    `{uid}-archive/...` too; and `..` resolves outside the folder it names.
    All three delete live users' reports, which is unrecoverable.
    """
    if not prefix:
        raise ValueError("a purge prefix must not be empty")
    if not prefix.endswith("/"):
        raise ValueError(f"a purge prefix must name a folder: {prefix!r}")
    if ".." in prefix:
        raise ValueError(f"a purge prefix must not contain ..: {prefix!r}")


def _objects_under(supabase, bucket: str, prefix: str) -> list[str]:
    rows = (
        supabase.rpc("storage_objects_under", {"p_bucket": bucket, "p_prefix": prefix})
        .execute()
        .data
    )
    return [row["name"] for row in rows or []]


def _record_failure(supabase, purge: dict, error: str) -> None:
    supabase.table("storage_purges").update({
        "attempts": int(purge.get("attempts") or 0) + 1,
        "last_error": error[:500],
    }).eq("id", purge["id"]).execute()


def purge_storage(supabase: Any, now: datetime | None = None) -> dict:
    """Reclaim the objects behind every outstanding purge. Never raises."""
    now = now or datetime.now(timezone.utc)

    try:
        purges = (
            supabase.table("storage_purges")
            .select("id,bucket_id,path_prefix,attempts")
            .is_("purged_at", "null")
            .order("created_at")
            .range(0, _PREFIX_LIMIT - 1)
            .execute()
            .data
        )
    except Exception:
        logger.exception("storage purge could not read its queue")
        return {"prefixes": 0, "objects": 0}

    done, removed = 0, 0
    for purge in purges or []:
        bucket, prefix = purge.get("bucket_id"), purge.get("path_prefix") or ""
        try:
            _validate(prefix)
            paths = _objects_under(supabase, bucket, prefix)
            for start in range(0, len(paths), _REMOVE_BATCH):
                batch = paths[start : start + _REMOVE_BATCH]
                # Through the Storage API, not by deleting the row: only this
                # also reclaims the object behind it.
                supabase.storage.from_(bucket).remove(batch)
            removed += len(paths)
        except Exception as error:
            # Left on the queue on purpose. One bad prefix must not stop the
            # others, and must never be mistaken for a completed purge.
            logger.exception(f"storage purge failed for {prefix!r}")
            try:
                _record_failure(supabase, purge, str(error) or type(error).__name__)
            except Exception:
                logger.exception("storage purge could not record its own failure")
            continue

        try:
            supabase.table("storage_purges").update({
                "purged_at": now.isoformat(),
                "last_error": None,
            }).eq("id", purge["id"]).execute()
        except Exception:
            # The bytes are gone, which is the part that matters; the row will
            # be retried and find nothing left to remove.
            logger.exception(f"storage purge removed {prefix!r} but could not mark it done")
            continue
        done += 1

    if done or removed:
        logger.info(f"storage purge: {removed} object(s) across {done} prefix(es)")
    return {"prefixes": done, "objects": removed}
