"""What is this caller, on the platform?

`auth.py` answers "who" from a verified token and never from a path, query or
body. This answers "what" and obeys the same rule with one addition, which is
the whole reason F9 exists:

**The role comes from the column. Never from the token.**

The prototype this programme is parity with keeps the role in `AsyncStorage`
and every endpoint trusts it. That is a cross-tenant leak with a feature
request in front of it. Here the column on `profiles` is the fact; a JWT claim
— if one is ever added, and today none is — is a cache that grants nothing on
its own. `tests/test_app_role.py` mints a genuinely-signed token carrying
`app_role: admin` for a user whose column says `member` and asserts a 403.

**This is the second gate, not the first.** RLS refuses a member reading an
admin row directly; this refuses our own endpoints serving one. Both are
needed and neither is sufficient: the gateway holds service-role credentials
and is not bound by RLS at all, and the router on the phone is not a security
boundary. CLAUDE.md's rule is that application code is *solely* responsible
for tenant isolation on our side of the line.

**Resolved per request, never cached.** The same discipline as
`clinician_may_sign` being evaluated at signing time rather than at claim
time: a role revoked while somebody has a screen open has to take effect on
their next request, not on their next sign-in. One indexed primary-key read
is the right price for that.
"""

from typing import Annotated, Any, Callable

from fastapi import Depends, HTTPException

from app.common.logging_config import get_logger, log_context
from app.common.supabase_client import get_supabase_client
from app.gateway.auth import current_user_id

logger = get_logger(__name__)

MEMBER = "member"
DOCTOR = "doctor"
CENTRE = "centre"
ADMIN = "admin"

#: The four, and the same four the check constraint in 022_app_role.sql
#: allows. A value outside this set is not trusted as itself — see below.
APP_ROLES = frozenset({MEMBER, DOCTOR, CENTRE, ADMIN})


def app_role_of(supabase: Any, user_id: str) -> str:
    """This person's platform role, read from `profiles.app_role`.

    Projected to the one column: `profiles` carries a name, an email and a
    phone number, and a role check has no business reading any of them.

    Returns `member` rather than raising in all three of the ways this can
    come back empty — no row, an unreadable table, an unrecognised value —
    because every one of them is a reason to grant less rather than more.
    """
    try:
        rows = (
            supabase.table("profiles")
            .select("app_role")
            .eq("id", user_id)
            .limit(1)
            .execute()
            .data
        )
    except Exception:
        # A role lookup that fails has to fail closed. Logged at exception
        # level because a database we cannot read is not a normal condition
        # even though the response to it is the ordinary one.
        logger.exception(f"could not resolve a platform role {log_context(user_id=user_id)}")
        return MEMBER

    if not rows:
        # Somebody mid-signup, before `handle_new_user` has run. Not an error,
        # and the safe reading of "no row" is the least privileged role rather
        # than a None every caller then has to remember to handle.
        return MEMBER

    role = str(rows[0].get("app_role") or "").strip()
    if role not in APP_ROLES:
        # The column is constrained, so this means the constraint was widened
        # without this file being updated. An unrecognised role must not fall
        # through as itself and get compared against an allow-list downstream,
        # where it might match one.
        logger.warning(
            f"profiles.app_role holds {role!r}, which this gateway does not "
            f"know {log_context(user_id=user_id)}"
        )
        return MEMBER
    return role


def require_app_role(*allowed: str) -> Callable[..., str]:
    """A FastAPI dependency admitting only these platform roles.

    Takes nothing from the request. `current_user_id` is the only input and it
    comes from the token's subject, so there is no parameter anywhere in the
    chain that a caller could supply to change the answer.

    Returns the resolved role, so an endpoint that serves two roles slightly
    differently does not have to look it up a second time.
    """
    # An empty allow-list is a programming mistake, and the safe reading of it
    # is a closed door. Checked at import time where possible, because the
    # alternative is a route that silently admits nobody.
    unknown = set(allowed) - APP_ROLES
    if unknown:
        raise ValueError(f"not a platform role: {', '.join(sorted(unknown))}")

    permitted = frozenset(allowed)

    def dependency(
        user_id: Annotated[str, Depends(current_user_id)],
        supabase: Annotated[Any, Depends(get_supabase_client)],
    ) -> str:
        role = app_role_of(supabase, user_id)
        if role not in permitted:
            # The caller is told nothing beyond "no". A 403 that named the
            # role would tell a prober which roles exist and which one they
            # hold; the reason goes to our logs, as with auth.py's 401s.
            logger.info(
                f"refused a {role} at a route for "
                f"{'/'.join(sorted(permitted)) or 'nobody'} "
                f"{log_context(user_id=user_id)}"
            )
            raise HTTPException(status_code=403, detail="not permitted")
        return role

    return dependency
