"""The platform admin surface.

The fourth role, and the only one with nothing in the prototype to port from.
Nothing in that repository corresponds to it; what it must do is already
visible in this codebase's own failure modes.

  * `stranded_total` has existed since F5 and nobody has ever been able to see
    it. It counts drafts that were flagged for a human, expired, and can never
    be delivered — people who were noticed and will not be told. The scheduler
    logs it into a log nobody reads.
  * Fifty catalog entries across five files are blocked on a clinical
    signature, with no interface anywhere to collect one.
  * DPDP gives a user erasure rights that somebody has to be able to honour
    and prove.

Two rules shape every endpoint here.

**Counts, not people.** No route on this surface returns a draft body, a
measurement, a conversation or a genotype, and `tests/test_admin_api.py`
asserts that by reading whole responses as text against a database holding all
four. The database agrees independently: 022 gives the admin role no policy on
any of those tables, so an admin authenticated as themselves reads zero rows.
This surface runs under the service role, which RLS does not bind, so the two
gates are doing different jobs and both are needed.

**The admin cannot sign.** `POST /catalogue/signoff` admits `doctor` and
refuses `admin`, which reads backwards until you remember what a signature is
for: an admin who can file a signature in a clinician's name has produced
nothing worth collecting. The admin's half is seeing what is waiting and
carrying the result into git.
"""

from datetime import datetime, timezone
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from app.clinical import reviewable
from app.clinical.reviewable import StaleSignature
from app.clinical.sweep import queue_health
from app.common.logging_config import get_logger, log_context
from app.common.supabase_client import get_supabase_client
from app.gateway.auth import current_user_id
from app.gateway.roles import ADMIN, APP_ROLES, DOCTOR, require_app_role

logger = get_logger(__name__)

router = APIRouter(prefix="/api/v1/admin", tags=["admin"])

#: A licence inside this window is worth putting on a screen. Long enough that
#: somebody can act, short enough that the list is not everybody.
LAPSE_WARNING_DAYS = 60

AUDIT_PAGE = 100


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _parse(when: Any) -> datetime | None:
    if not when:
        return None
    try:
        return datetime.fromisoformat(str(when).replace("Z", "+00:00"))
    except ValueError:
        return None


# ── The dashboard ────────────────────────────────────────────────────────────

@router.get("/platform")
def read_platform(
    _: Annotated[str, Depends(require_app_role(ADMIN))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    """What state the platform is in, in numbers an admin can act on.

    Always a 200. Every section degrades to nulls rather than failing the
    whole page, because the single most likely reason one of them cannot be
    read is the incident the admin opened this screen to look at.
    """
    return {
        "queue": queue_health(supabase),
        "catalogue": reviewable.summary(),
        "roles": _role_counts(supabase),
        "clinicians": _clinician_health(supabase),
    }


def _role_counts(supabase) -> dict:
    """How many accounts hold each role.

    Every role is present in the result even at zero. A dashboard that omits
    `centre: 0` reads as a dashboard that does not know about centres, which
    is a different and much more worrying thing.
    """
    counts = {role: 0 for role in sorted(APP_ROLES)}
    try:
        rows = (
            supabase.table("profiles")
            .select("app_role")
            .execute()
            .data
        ) or []
    except Exception:
        logger.exception("could not count the roles")
        return counts
    for row in rows:
        role = str(row.get("app_role") or "").strip()
        if role in counts:
            counts[role] += 1
    return counts


def _clinician_health(supabase) -> dict:
    """Who can sign, and whose licence is about to stop them.

    The headline number is `active`, and today it is one, and it is a fixture
    from `dev_clinical_demo.sql`. Every draft strands until that changes, so
    the number belongs on the first screen rather than in a report.

    A lapse should be noticed here rather than discovered as a refused
    signature, which is what `clinician_may_sign` turns it into at the worst
    possible moment — a clinician mid-review, told no.
    """
    try:
        rows = (
            supabase.table("clinicians")
            .select("user_id,full_name,registration_number,status,"
                    "licence_expires_at")
            .execute()
            .data
        ) or []
    except Exception:
        logger.exception("could not read clinician registrations")
        return {"active": None, "suspended": None, "expiring_soon": []}

    now = _now()
    active, suspended, expiring = 0, 0, []
    for row in rows:
        if row.get("status") == "suspended":
            suspended += 1
            continue
        expires = _parse(row.get("licence_expires_at"))
        if expires is None:
            continue
        days_left = (expires - now).days
        if row.get("status") == "active" and days_left >= 0:
            active += 1
        if days_left <= LAPSE_WARNING_DAYS:
            expiring.append({
                "full_name": row.get("full_name"),
                "registration_number": row.get("registration_number"),
                "days_left": days_left,
                "expired": days_left < 0,
            })
    expiring.sort(key=lambda row: row["days_left"])
    return {"active": active, "suspended": suspended,
            "expiring_soon": expiring}


# ── The audit trail ──────────────────────────────────────────────────────────

@router.get("/audit")
def read_audit(
    _: Annotated[str, Depends(require_app_role(ADMIN))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
    limit: int = Query(default=AUDIT_PAGE, ge=1, le=500),
) -> dict:
    """What admins have done, newest first.

    Including the admin reading it. There is no "except mine" clause here or
    in the policy behind it, and there must never be one: a trail an actor can
    exclude themselves from answers nothing in the dispute it exists for.
    """
    rows = (
        supabase.table("admin_actions")
        .select("id,actor_id,action,subject_kind,subject_id,detail,created_at")
        .order("created_at", desc=True)
        .limit(limit)
        .execute()
        .data
    ) or []
    return {"items": rows}


# ── The catalogue surface ────────────────────────────────────────────────────

@router.get("/catalogue")
def read_catalogue(
    _: Annotated[str, Depends(require_app_role(ADMIN))],
) -> dict:
    """Every entry in all five reviewed-content files, signed or not.

    Reads no database: the content and its signature state both live in git,
    which is the whole point of the split. What `catalog_signoffs` holds is
    the act of signing, and that is the block endpoint's business.
    """
    return {
        "catalogues": [
            {
                "name": catalogue.name,
                "path": catalogue.path,
                "version": catalogue.version,
                "entries": [
                    {
                        "entry_id": entry.entry_id,
                        "label": entry.label,
                        "fingerprint": entry.fingerprint,
                        "signed": entry.signed,
                        "reviewer": entry.reviewer,
                        "reviewed_at": entry.reviewed_at,
                    }
                    for entry in catalogue.entries
                ],
            }
            for catalogue in reviewable.catalogues()
        ]
    }


class SignoffRequest(BaseModel):
    """What a clinician sends when they sign an entry.

    Note what is absent: the signatory. CLAUDE.md's rule for tools is that
    `user_id` never arrives as a parameter, and a signature whose signatory is
    a body field is a signature anybody can forge. It comes from the token.

    `content_sha256` is required and is not a convenience. Sending it is the
    client asserting *which text* was on the screen when the clinician agreed,
    and the server refuses if the file has moved since.
    """

    catalogue: str = Field(min_length=1, max_length=40)
    entry_id: str = Field(min_length=1, max_length=120)
    content_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    notes: str | None = Field(default=None, max_length=2000)

    model_config = {"extra": "ignore"}


@router.post("/catalogue/signoff", status_code=201)
def record_signoff(
    body: SignoffRequest,
    # `DOCTOR`, not `ADMIN`. See the module docstring: the admin collects the
    # signature and the clinician makes it. The licence itself is checked by
    # the trigger on `catalog_signoffs`, at signing time, so this role check
    # is about which surface you are on and not about whether you may sign.
    _: Annotated[str, Depends(require_app_role(DOCTOR))],
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    catalogue = reviewable.get(body.catalogue)
    if catalogue is None:
        raise HTTPException(
            status_code=409,
            detail=f"{body.catalogue} is not a reviewable catalogue",
        )

    current = reviewable.fingerprint_for(body.catalogue, body.entry_id)
    if current is None:
        raise HTTPException(
            status_code=409,
            detail=f"{body.entry_id} is not an entry in {catalogue.path}",
        )
    if current != body.content_sha256:
        # Signing text nobody read, refused at the door. Discovering this
        # later means a clinician's name sits in git against a block the
        # loader ignores, with no symptom but a screen still saying nobody
        # has reviewed this.
        raise HTTPException(
            status_code=409,
            detail=(
                f"{body.entry_id} has changed since it was read. Reload it "
                "and read it again before signing."
            ),
        )

    row = {
        "catalog": body.catalogue,
        "catalog_version": catalogue.version,
        "entry_id": body.entry_id,
        "content_sha256": body.content_sha256,
        # From the token's subject. The trigger stamps the name and the
        # registration from `clinicians`, so neither is sent and neither can
        # be chosen.
        "clinician_id": user_id,
        "action": "signed",
        "notes": body.notes,
    }
    supabase.table("catalog_signoffs").insert(row).execute()
    logger.info(
        f"a catalog entry was signed {log_context(user_id=user_id)} "
        f"catalogue={body.catalogue} entry={body.entry_id}"
    )
    return {"status": "recorded", "catalogue": body.catalogue,
            "entry_id": body.entry_id}


@router.get("/catalogue/{name}/block")
def read_block(
    name: str,
    _: Annotated[str, Depends(require_app_role(ADMIN))],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    """The `clinical_review:` block to commit into that file.

    The last step of collecting a signature is a human committing a file, so
    the surface hands them the exact text rather than a description of it.
    """
    catalogue = reviewable.get(name)
    if catalogue is None:
        raise HTTPException(status_code=404, detail="no such catalogue")

    rows = (
        supabase.table("catalog_signoffs")
        .select("entry_id,content_sha256,action,reviewer_name,"
                "reviewer_registration,signed_at,seq")
        .eq("catalog", name)
        .order("seq", desc=False)
        .execute()
        .data
    ) or []

    # Latest action per (entry, hash), mirroring `catalog_signoff_state`. Done
    # here rather than through the function because this runs under the
    # service role over PostgREST, which cannot call a set-returning function
    # with the same ease; the ordering rule is the same one and is the thing
    # that has to match.
    latest: dict[tuple[str, str], dict] = {}
    for row in rows:
        latest[(row["entry_id"], row["content_sha256"])] = row

    signatures = [
        reviewable.Signature(
            entry_id=row["entry_id"],
            content_sha256=row["content_sha256"],
            # One string, because that is what the YAML field holds and what a
            # reader of the file needs: a name alone is not a signatory.
            reviewer=f"{row['reviewer_name']}, {row['reviewer_registration']}",
            reviewed_at=str(row["signed_at"])[:10],
        )
        for row in latest.values()
        if row.get("action") == "signed"
    ]

    if not signatures:
        # Deliberately not an empty block. `clinical_review: {markers: []}`
        # committed over a real one would withdraw every signature in the file.
        return {"path": catalogue.path, "signatures": 0, "block": None}

    try:
        block = reviewable.signoff_block(name, signatures)
    except StaleSignature as stale:
        # A real signature that no longer applies. Reported rather than
        # silently dropped, because somebody has to decide whether to ask for
        # a re-read or to revert the edit.
        raise HTTPException(status_code=409, detail=str(stale)) from None

    return {"path": catalogue.path, "signatures": len(signatures),
            "block": block}
