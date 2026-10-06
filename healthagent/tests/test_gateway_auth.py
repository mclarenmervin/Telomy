"""The gateway's identity primitive.

Every REST endpoint derives the user from a verified token and never from a
path, query or body parameter — the same rule the agent's tools follow for
`user_id`, for the same reason: it makes cross-tenant access impossible by
construction rather than by remembering to check.
"""

import json
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException

from app.gateway.auth import JwtVerifier

AUDIENCE = "authenticated"
ALICE = "00000000-0000-0000-0000-00000000000a"


def make_key(kid="k1"):
    private = ec.generate_private_key(ec.SECP256R1())
    jwk = json.loads(jwt.algorithms.ECAlgorithm.to_jwk(private.public_key()))
    jwk.update({"kid": kid, "alg": "ES256", "use": "sig"})
    return private, jwk


def token_for(private, kid="k1", sub=ALICE, aud=AUDIENCE, expires_in=3600, **extra):
    claims = {"sub": sub, "aud": aud, "exp": int(time.time()) + expires_in}
    claims.update(extra)
    if sub is None:
        claims.pop("sub")
    return jwt.encode(claims, private, algorithm="ES256", headers={"kid": kid})


class FakeJwks:
    """Stands in for the Supabase JWKS endpoint, and counts fetches so key
    rotation can be tested without a network."""

    def __init__(self, *jwks):
        self.responses = list(jwks)
        self.calls = 0

    def __call__(self):
        self.calls += 1
        return self.responses[min(self.calls - 1, len(self.responses) - 1)]


def verifier_for(*jwks, **kwargs):
    fetch = FakeJwks(*[{"keys": list(j)} for j in jwks])
    return JwtVerifier(audience=AUDIENCE, fetch_jwks=fetch, **kwargs), fetch


def test_a_valid_token_yields_its_subject():
    private, jwk = make_key()
    verifier, _ = verifier_for([jwk])

    assert verifier.user_id(f"Bearer {token_for(private)}") == ALICE


def test_an_expired_token_is_rejected():
    private, jwk = make_key()
    verifier, _ = verifier_for([jwk])

    with pytest.raises(HTTPException) as err:
        verifier.user_id(f"Bearer {token_for(private, expires_in=-60)}")

    assert err.value.status_code == 401


def test_a_token_signed_by_another_key_is_rejected():
    """The attack this exists to stop: a well-formed token someone else minted."""
    _, our_jwk = make_key()
    attacker_key, _ = make_key()
    verifier, _ = verifier_for([our_jwk])

    with pytest.raises(HTTPException):
        verifier.user_id(f"Bearer {token_for(attacker_key)}")


def test_an_unsigned_token_is_rejected():
    """alg=none must never be accepted, however well-formed the claims are."""
    _, jwk = make_key()
    verifier, _ = verifier_for([jwk])
    unsigned = jwt.encode({"sub": ALICE, "aud": AUDIENCE}, key=None, algorithm="none")

    with pytest.raises(HTTPException):
        verifier.user_id(f"Bearer {unsigned}")


def test_a_token_for_another_audience_is_rejected():
    private, jwk = make_key()
    verifier, _ = verifier_for([jwk])

    with pytest.raises(HTTPException):
        verifier.user_id(f"Bearer {token_for(private, aud='some-other-service')}")


def test_a_token_without_a_subject_is_rejected():
    private, jwk = make_key()
    verifier, _ = verifier_for([jwk])

    with pytest.raises(HTTPException):
        verifier.user_id(f"Bearer {token_for(private, sub=None)}")


def test_a_missing_or_malformed_header_is_rejected():
    _, jwk = make_key()
    verifier, _ = verifier_for([jwk])

    for header in (None, "", "Bearer", "Basic abc", "notbearer x.y.z"):
        with pytest.raises(HTTPException) as err:
            verifier.user_id(header)
        assert err.value.status_code == 401


def test_keys_are_cached_rather_than_fetched_per_request():
    private, jwk = make_key()
    verifier, fetch = verifier_for([jwk])

    for _ in range(5):
        verifier.user_id(f"Bearer {token_for(private)}")

    assert fetch.calls == 1


def test_an_unknown_kid_refreshes_the_keys_once():
    """Supabase rotates signing keys. A token with a kid we have never seen is a
    reason to refetch exactly once, not a reason to reject outright."""
    old_private, old_jwk = make_key("old")
    new_private, new_jwk = make_key("new")
    verifier, fetch = verifier_for([old_jwk], [old_jwk, new_jwk])

    verifier.user_id(f"Bearer {token_for(old_private, kid='old')}")
    assert verifier.user_id(f"Bearer {token_for(new_private, kid='new')}") == ALICE
    assert fetch.calls == 2


def test_an_unknown_kid_does_not_refetch_on_every_request():
    """A flood of tokens with bogus kids must not turn into a flood of fetches."""
    private, jwk = make_key("real")
    attacker, bogus_jwk = make_key("bogus")
    verifier, fetch = verifier_for([jwk])

    for _ in range(5):
        with pytest.raises(HTTPException):
            verifier.user_id(f"Bearer {token_for(attacker, kid='bogus')}")

    assert fetch.calls <= 2
