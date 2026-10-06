"""Reading uploaded lab reports, and confirming what we read.

Confirmation is not a formality, and it is why 007 removed the phone's ability
to set `biomarker_results.status` itself. This is the only path on which four
things happen:

  * **the patient-name check** — the report may be a family member's, and one
    phone per household is common here
  * **the collection date** — captured when extraction could not read one
    confidently, because trending uses it and guessing puts an old panel on
    today's chart
  * **the projection into `health_measurements` with `origin='server'`** —
    without that column `save_normalized_wellness` deletes the row on the user's
    next sync, days later, looking like an extraction bug
  * **the score recompute** — queued, never run inline

Thin otherwise, like the scores router. The caller comes from the verified token
and there is no `user_id` in any path, query or body.
"""

import uuid
from datetime import datetime
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.analytics import units
from app.analytics.reference_ranges import RangeResolver, grade_for_display
from app.common.logging_config import get_logger, log_context
from app.common.queue import JobQueue
from app.common.supabase_client import get_supabase_client
from app.gateway.auth import current_user_id
from app.gateway.queue_provider import get_score_queue
from app.scheduler.plan import SCORE_RECOMPUTE

router = APIRouter(prefix="/api/v1/labs", tags=["labs"])
logger = get_logger(__name__)

CONFIRMED = "confirmed"
CORRECTED = "corrected"
REJECTED = "rejected"

# Statuses a report can be confirmed from. Anything else has either not been
# read yet or has been through this already.
CONFIRMABLE = frozenset({"extracted"})

_APPLIED = {"confirm": CONFIRMED, "correct": CORRECTED, "reject": REJECTED}


class Decision(BaseModel):
    result_id: str
    action: Literal["confirm", "correct", "reject"]
    value: float | None = None
    unit: str | None = None


class ConfirmRequest(BaseModel):
    decisions: list[Decision]
    collected_at: datetime | None = None
    # Only consulted when a name was extracted. Absent is not the same as False.
    patient_is_me: bool | None = None


def _upload(supabase, upload_id: str, user_id: str) -> dict:
    rows = (
        supabase.table("lab_uploads")
        .select("*")
        .eq("id", upload_id)
        .eq("user_id", user_id)  # the isolation boundary
        .execute()
        .data
    )
    if not rows:
        # 404 rather than 403: whether someone else's upload exists is not ours
        # to disclose.
        raise HTTPException(status_code=404, detail="no such upload")
    return rows[0]


def _results(supabase, upload_id: str, user_id: str) -> list[dict]:
    return (
        supabase.table("biomarker_results")
        .select("*")
        .eq("upload_id", upload_id)
        .eq("user_id", user_id)
        .execute()
        .data
    )


@router.get("/uploads")
def list_uploads(
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> list[dict]:
    return (
        supabase.table("lab_uploads")
        .select("*")
        .eq("user_id", user_id)
        .order("created_at", desc=True)
        .range(0, 49)
        .execute()
        .data
    )


@router.get("/uploads/{upload_id}")
def read_upload(
    upload_id: str,
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    """The report and everything read off it, for the confirmation screen."""
    upload = _upload(supabase, upload_id, user_id)
    resolver = RangeResolver()

    results = []
    for row in _results(supabase, upload_id, user_id):
        resolved = resolver.resolve(row["biomarker_id"], user_id)
        results.append({
            **row,
            # `grade_for_display`, never `grade`: until a clinician has signed
            # the catalog off this is `ungraded`, and the screen shows the
            # number as printed with no verdict attached.
            "grade": grade_for_display(row.get("value_canonical"), resolved),
        })
    return {"upload": upload, "results": results}


def _canonical_correction(biomarker_id: str, value: float, unit: str | None) -> float:
    try:
        return units.to_canonical(biomarker_id, value, unit)
    except (units.UnknownUnit, ValueError, TypeError) as error:
        # Refused rather than stored as given: a value in an unknown unit is not
        # comparable with anything, and guessing is how a unit bug becomes
        # indistinguishable from a real abnormal result.
        raise HTTPException(
            status_code=422,
            detail=f"cannot convert {value} {unit!r} for {biomarker_id}",
        ) from error


@router.post("/uploads/{upload_id}/confirm")
def confirm_upload(
    upload_id: str,
    request: ConfirmRequest,
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    queue: Annotated[JobQueue, Depends(get_score_queue)],
) -> dict:
    upload = _upload(supabase, upload_id, user_id)
    context = log_context(user_id=user_id)

    if upload.get("status") not in CONFIRMABLE:
        # Confirming twice would project every value twice and double the chart.
        raise HTTPException(
            status_code=409,
            detail=f"this report is {upload.get('status')} and cannot be confirmed",
        )

    if upload.get("patient_name") and request.patient_is_me is not True:
        raise HTTPException(
            status_code=409,
            detail=(
                f"this report names {upload['patient_name']}. Confirm it is you "
                f"before we add it to your record."
            ),
        )

    collected_at = request.collected_at
    if collected_at is None:
        if not upload.get("collected_at") or upload.get("collected_at_source") != "extracted":
            raise HTTPException(
                status_code=422,
                detail="we could not read the collection date; please supply it",
            )
        collected_at_iso = upload["collected_at"]
        collected_at_source = upload["collected_at_source"]
    else:
        collected_at_iso = collected_at.isoformat()
        collected_at_source = "user"

    results = {row["id"]: row for row in _results(supabase, upload_id, user_id)}
    decided = {d.result_id for d in request.decisions}

    unknown = decided - set(results)
    if unknown:
        raise HTTPException(
            status_code=422, detail=f"these results are not on this report: {sorted(unknown)}"
        )
    undecided = set(results) - decided
    if undecided:
        # A silent partial confirmation leaves rows nobody looks at again:
        # invisible to every score and invisible to the user.
        raise HTTPException(
            status_code=422, detail=f"every result needs a decision; missing {sorted(undecided)}"
        )

    # Everything that could be refused is refused before anything is written.
    planned = []
    for decision in request.decisions:
        row = results[decision.result_id]
        update = {
            "status": _APPLIED[decision.action],
            "collected_at": collected_at_iso,
            "confirmed_at": datetime.now().astimezone().isoformat(),
        }
        if decision.action == "correct":
            if decision.value is None:
                raise HTTPException(status_code=422, detail="a correction needs a value")
            unit = decision.unit or row.get("raw_unit")
            update["value_canonical"] = _canonical_correction(
                row["biomarker_id"], decision.value, unit
            )
            update["raw_value"] = str(decision.value)
            update["raw_unit"] = unit
        planned.append((row, update))

    projected = 0
    for row, update in planned:
        supabase.table("biomarker_results").update(update).eq("id", row["id"]).execute()

        if update["status"] == REJECTED:
            continue
        if row.get("operator", "=") != "=":
            # `health_measurements` has no operator column, so a projected `<3.0`
            # is indistinguishable from a measured 3.0 and would reach biological
            # age. Censored values stay in biomarker_results, where the operator
            # survives — the exclusion is structural rather than remembered.
            continue

        supabase.table("health_measurements").insert({
            "id": str(uuid.uuid4()),  # this table has no default
            "user_id": user_id,
            "measurement_type": row["biomarker_id"],
            "value": update.get("value_canonical", row.get("value_canonical")),
            "unit": row.get("unit_canonical") or "",
            "recorded_at": collected_at_iso,
            "source": "lab_extraction",
            "quality": "measured",
            "origin": "server",  # or the phone's next sync deletes it
        }).execute()
        projected += 1

    supabase.table("lab_uploads").update({
        "status": CONFIRMED,
        "collected_at": collected_at_iso,
        "collected_at_source": collected_at_source,
    }).eq("id", upload_id).execute()

    # Queued, never inline: a bulk upload of five years of reports would
    # otherwise recompute scores synchronously inside a request.
    queue.enqueue({
        "kind": SCORE_RECOMPUTE,
        "user_id": user_id,
        "as_of": collected_at_iso[:10],
    })

    logger.info(
        f"upload {upload_id} confirmed: {projected} projected of "
        f"{len(planned)} decided {context}"
    )
    return {"confirmed": True, "projected": projected, "decided": len(planned)}
