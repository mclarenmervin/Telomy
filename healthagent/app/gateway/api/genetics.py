"""What we hold from somebody's genome, for their own screen.

Deliberately narrow. This returns a person their own stored genotypes with
the gene and trait attached, because `rs855791 · AA` is accurate and tells
them nothing — and it returns the *meaning* of a variant only once a
clinician has signed it off, which is the same line every other catalog in
this product draws.

**This is not the agent's path and must not become it.** The concierge
reaches variants only through `get_lab_results`, attached to a marker the
user actually has, and there is no tool that lists them. A person reading
their own record is a different act from a model being handed genotypes to
reason about, and the difference is the whole of the plan's rule that a
variant may never originate an insight.
"""

from typing import Annotated, Any

from fastapi import APIRouter, Depends

from app.analytics.genetics import describe_stored
from app.common.supabase_client import get_supabase_client
from app.gateway.auth import current_user_id

router = APIRouter(prefix="/api/v1/genetics", tags=["genetics"])


@router.get("/variants")
def read_variants(
    user_id: Annotated[str, Depends(current_user_id)],
    supabase: Annotated[Any, Depends(get_supabase_client)],
) -> dict:
    """The allowlisted genotypes we hold for this person."""
    rows = (
        supabase.table("genetic_variants")
        .select("rsid,genotype")
        .eq("user_id", user_id)
        .execute()
        .data
    )
    return {"items": describe_stored(rows)}
