"""Importing genetics uploads the webhook did not reach.

**The webhook is an optimisation here, not a dependency**, and that is a
deliberate difference from the lab path.

A lab upload's trigger has existed since F3 and the sweep only reconciles
the two ways a report gets stuck. `genetic_uploads` has no trigger at all:
the one on `lab_uploads` was created in the Supabase dashboard because it
embeds the shared secret, and a migration cannot create it. So the genetics
feature shipped depending on somebody remembering to click something, and
the failure mode if they do not is a person watching "Reading your file…"
forever, with nothing in any log to say why.

That is a bad thing to depend on a click for, and it is cheap not to. An
import is a text parse of a few hundred milliseconds with no OCR and no
model, the scheduler already ticks every minute, and the rows are found by
a partial-index lookup that returns nothing almost always. So this picks up
anything sitting at `uploaded` and runs it, whether a webhook fired or not.

Running both is safe: the handler re-reads the row and skips anything that
is not still `uploaded`, which is the same guard that makes a webhook retry
harmless.
"""

from typing import Any

from app.common.logging_config import get_logger
from app.extraction_worker.genetics_handler import UPLOADED, process_genetics_job

logger = get_logger(__name__)

#: Enough to clear a backlog without scanning the table. A person uploads a
#: genome once or twice, ever, so a queue of more than this means something
#: else is wrong and the next tick will take the rest anyway.
SWEEP_LIMIT = 25


def sweep_genetics(supabase: Any) -> dict:
    """Import anything still waiting. Never raises."""
    try:
        rows = (
            supabase.table("genetic_uploads")
            .select("id,user_id")
            .eq("status", UPLOADED)
            .order("created_at")
            .limit(SWEEP_LIMIT)
            .execute()
            .data
        )
    except Exception:
        logger.exception("could not list waiting genetic uploads")
        return {"imported": 0}

    for row in rows:
        # The handler never raises and re-checks the status itself, so a
        # webhook that beat us here simply finds the row already done.
        process_genetics_job(
            {"upload_id": row.get("id"), "user_id": row.get("user_id")}, supabase
        )

    if rows:
        logger.info(f"genetics sweep picked up {len(rows)} waiting upload(s)")
    return {"imported": len(rows)}
