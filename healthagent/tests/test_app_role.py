"""The gateway's second identity question: not who, but what.

`current_user_id` answers "who is this" from a verified token and never from
a path, query or body. Role resolution sits beside it and obeys the same rule
with one addition that is the whole point of the phase: **the role comes from
the column, never from the token**. A claim is a cache; the database is the
fact.

The test that matters here is `test_a_stale_claim_grants_nothing`, and it is
deliberately end to end through the real verifier rather than through an
overridden dependency. A token is minted carrying `app_role: admin` for a
user whose column says `member`, signed with a key the verifier genuinely
trusts — so the request is not forged in any way the gateway could detect,
and the only thing standing between it and an admin surface is that nothing
reads the claim. The database half of the same property is in
db/tests/app_role_test.sql; this is the half that binds our own code, which
holds the service role and is not bound by RLS at all.
"""

import json
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import Depends, FastAPI, HTTPException
from fastapi.testclient import TestClient

from app.common.supabase_client import get_supabase_client
from app.gateway import auth as auth_module
from app.gateway.auth import JwtVerifier, current_user_id
from app.gateway.roles import ADMIN, CENTRE, DOCTOR, MEMBER, app_role_of, require_app_role
from tests.fakes import FakeSupabase

ALICE = "00000000-0000-0000-0000-00000000000a"
AUDIENCE = "authenticated"


def profile(user_id=ALICE, app_role=MEMBER):
    return {"id": user_id, "full_name": "Alex", "app_role": app_role}


# ── Resolving the role ───────────────────────────────────────────────────────

def test_the_role_is_read_from_the_column():
    db = FakeSupabase({"profiles": [profile(app_role=ADMIN)]})

    assert app_role_of(db, ALICE) == ADMIN


def test_an_account_with_no_profile_row_is_a_member():
    """Somebody mid-signup is not an error, and the safe reading of "no row"
    is the least privileged role rather than a None every caller then has to
    remember to handle. Matches the SQL function's own coalesce."""
    db = FakeSupabase({"profiles": []})

    assert app_role_of(db, ALICE) == MEMBER


class ExplodingDatabase:
    """A database that cannot answer. Modelled rather than stubbed because the
    interesting thing is that the caller never learns why."""

    def table(self, name):
        raise RuntimeError("no connection")


def test_a_lookup_that_fails_grants_nothing():
    """A role lookup that cannot complete has to fail closed.

    Found by mutation: returning ADMIN from the exception path left all
    fifteen other tests green, because every one of them hands the resolver a
    database that works. A gateway that promoted everybody to admin during a
    database incident would be the worst possible failure mode and the
    hardest to notice, since the incident would be the thing in the logs.
    """
    assert app_role_of(ExplodingDatabase(), ALICE) == MEMBER


def test_a_role_nobody_designed_resolves_to_member():
    """Defence against the column being widened without this file being
    updated. A value we do not recognise must not fall through as itself and
    get compared against an allow-list somewhere downstream."""
    db = FakeSupabase({"profiles": [profile(app_role="superuser")]})

    assert app_role_of(db, ALICE) == MEMBER


def test_the_role_is_resolved_per_request_and_never_cached():
    """Same discipline as `clinician_may_sign` being evaluated at signing time:
    a role revoked while somebody is holding a screen open has to take effect
    on their next request, not on their next sign-in."""
    db = FakeSupabase({"profiles": [profile(app_role=ADMIN)]})
    assert app_role_of(db, ALICE) == ADMIN

    db.tables["profiles"][0]["app_role"] = MEMBER

    assert app_role_of(db, ALICE) == MEMBER


# ── The dependency ───────────────────────────────────────────────────────────

def app_for(db, user_id=ALICE, allowed=(ADMIN,)):
    app = FastAPI()

    @app.get("/admin/thing")
    def read(role: str = Depends(require_app_role(*allowed))):
        return {"role": role}

    app.dependency_overrides[current_user_id] = lambda: user_id
    app.dependency_overrides[get_supabase_client] = lambda: db
    return TestClient(app)


def test_an_unreachable_database_refuses_an_admin_route():
    """The same property at the route, not only at the resolver."""
    assert app_for(ExplodingDatabase()).get("/admin/thing").status_code == 403


def test_an_admin_reaches_an_admin_route():
    db = FakeSupabase({"profiles": [profile(app_role=ADMIN)]})

    response = app_for(db).get("/admin/thing")

    assert response.status_code == 200
    assert response.json() == {"role": ADMIN}


@pytest.mark.parametrize("role", [MEMBER, DOCTOR, CENTRE])
def test_every_other_role_is_refused(role):
    """The verification the phase asks for, from the API side: run as each of
    the other roles and get nothing."""
    db = FakeSupabase({"profiles": [profile(app_role=role)]})

    assert app_for(db).get("/admin/thing").status_code == 403


def test_the_refusal_says_nothing_about_who_the_caller_is():
    """A 403 that explained itself would tell a prober which roles exist and
    which one they hold. The reason goes to our logs, as with the 401s."""
    db = FakeSupabase({"profiles": [profile(app_role=MEMBER)]})

    body = app_for(db).get("/admin/thing").json()

    assert body["detail"] == "not permitted"
    assert MEMBER not in json.dumps(body)


def test_a_route_can_admit_more_than_one_role():
    db = FakeSupabase({"profiles": [profile(app_role=DOCTOR)]})

    response = app_for(db, allowed=(DOCTOR, ADMIN)).get("/admin/thing")

    assert response.status_code == 200


def test_a_route_that_admits_no_role_admits_nobody():
    """A `require_app_role()` with an empty list is a programming mistake, and
    the safe reading of it is a closed door rather than an open one."""
    db = FakeSupabase({"profiles": [profile(app_role=ADMIN)]})

    assert app_for(db, allowed=()).get("/admin/thing").status_code == 403


# ── Bite 1: the claim grants nothing ─────────────────────────────────────────

def make_key(kid="k1"):
    private = ec.generate_private_key(ec.SECP256R1())
    jwk = json.loads(jwt.algorithms.ECAlgorithm.to_jwk(private.public_key()))
    jwk.update({"kid": kid, "alg": "ES256", "use": "sig"})
    return private, jwk


def token_for(private, kid="k1", sub=ALICE, **extra):
    claims = {"sub": sub, "aud": AUDIENCE, "exp": int(time.time()) + 3600}
    claims.update(extra)
    return jwt.encode(claims, private, algorithm="ES256", headers={"kid": kid})


def real_auth_app(db, monkeypatch):
    """The gateway as deployed: a real verifier, and nothing overridden except
    where the keys come from and where the database is."""
    private, jwk = make_key()
    monkeypatch.setattr(
        auth_module, "_verifier",
        JwtVerifier(audience=AUDIENCE, fetch_jwks=lambda: {"keys": [jwk]}),
    )

    app = FastAPI()

    @app.get("/admin/thing")
    def read(role: str = Depends(require_app_role(ADMIN))):
        return {"role": role}

    app.dependency_overrides[get_supabase_client] = lambda: db
    return TestClient(app), private


def test_a_stale_claim_grants_nothing(monkeypatch):
    """A token signed by the real key, carrying `app_role: admin`, for a user
    whose column says member.

    Nothing about this request is detectably forged. It is refused because no
    code path reads the claim — which is the only reason a role cached in a
    token is safe to have at all.
    """
    db = FakeSupabase({"profiles": [profile(app_role=MEMBER)]})
    client, private = real_auth_app(db, monkeypatch)

    response = client.get(
        "/admin/thing",
        headers={"Authorization": f"Bearer {token_for(private, app_role=ADMIN)}"},
    )

    assert response.status_code == 403


def test_the_same_token_works_once_the_column_agrees(monkeypatch):
    """The other half, and the reason the test above proves something. Without
    this, a 403 could mean the token was rejected for any of a dozen reasons
    and the claim would be beside the point."""
    db = FakeSupabase({"profiles": [profile(app_role=ADMIN)]})
    client, private = real_auth_app(db, monkeypatch)

    # Note the claim says `member` here, and it is admitted anyway. The claim
    # is not consulted in either direction.
    response = client.get(
        "/admin/thing",
        headers={"Authorization": f"Bearer {token_for(private, app_role=MEMBER)}"},
    )

    assert response.status_code == 200


def test_an_anonymous_request_is_a_401_and_not_a_403(monkeypatch):
    """Role resolution never runs for a caller we cannot name, so the failure
    has to be about identity rather than about permission."""
    db = FakeSupabase({"profiles": [profile(app_role=ADMIN)]})
    client, _ = real_auth_app(db, monkeypatch)

    assert client.get("/admin/thing").status_code == 401


def test_the_role_is_never_taken_from_the_request(monkeypatch):
    """The rule `current_user_id` already holds, extended to the role: a query
    parameter saying `admin` is ignored, because the dependency takes no
    argument from the request at all."""
    db = FakeSupabase({"profiles": [profile(app_role=MEMBER)]})
    client, private = real_auth_app(db, monkeypatch)

    response = client.get(
        "/admin/thing?role=admin&app_role=admin",
        headers={"Authorization": f"Bearer {token_for(private)}"},
    )

    assert response.status_code == 403
