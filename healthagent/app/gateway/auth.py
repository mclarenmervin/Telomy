"""Who is this request from?

The gateway is a public URL. Every REST endpoint derives the caller from a
verified Supabase JWT and **never** from a path, query or body parameter — the
same rule the agent's tools follow for `user_id`, for the same reason: it makes
cross-tenant access impossible by construction rather than by remembering to
check.

Supabase signs with asymmetric keys (ES256) and publishes the public set at
`/auth/v1/.well-known/jwks.json`, so there is no shared secret to distribute to
this service. Keys rotate, so an unrecognised `kid` is a reason to refetch once
— but only once per cooldown, or a flood of forged tokens becomes a flood of
outbound requests.
"""

import json
import time
import urllib.request
from typing import Any, Callable

import jwt
from fastapi import Header, HTTPException

from app.common.config import get_settings
from app.common.logging_config import get_logger

logger = get_logger(__name__)

# Supabase issues access tokens with this audience for signed-in users.
DEFAULT_AUDIENCE = "authenticated"

# Only asymmetric signatures are accepted. Listing the algorithms explicitly is
# what stops an `alg: none` or an HS256-token-signed-with-the-public-key attack.
ALLOWED_ALGORITHMS = ("ES256", "RS256")

JWKS_TTL_SECONDS = 600
UNKNOWN_KID_COOLDOWN_SECONDS = 60


def _unauthorized(reason: str) -> HTTPException:
    # The caller is told nothing beyond "no"; the reason goes to our logs only.
    logger.info(f"rejected request: {reason}")
    return HTTPException(status_code=401, detail="invalid or missing credentials")


def _fetch_jwks_from(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=10) as response:  # noqa: S310 - fixed https URL
        return json.loads(response.read())


class JwtVerifier:
    """Verifies Supabase access tokens against the project's published keys."""

    def __init__(
        self,
        audience: str = DEFAULT_AUDIENCE,
        fetch_jwks: Callable[[], dict] | None = None,
        ttl_seconds: int = JWKS_TTL_SECONDS,
        now: Callable[[], float] = time.monotonic,
    ):
        self._audience = audience
        self._fetch_jwks = fetch_jwks
        self._ttl = ttl_seconds
        self._now = now
        self._keys: dict[str, Any] = {}
        self._fetched_at: float | None = None
        self._last_miss_refresh: float | None = None

    def _refresh(self) -> None:
        if self._fetch_jwks is None:
            raise _unauthorized("no JWKS source configured")
        try:
            jwks = self._fetch_jwks()
        except Exception:
            logger.exception("fetching JWKS failed; keeping the keys we have")
            return
        self._keys = {
            key["kid"]: jwt.PyJWK(key)
            for key in jwks.get("keys", [])
            if key.get("kid")
        }
        self._fetched_at = self._now()

    def _key_for(self, kid: str):
        stale = self._fetched_at is None or self._now() - self._fetched_at > self._ttl
        if stale:
            self._refresh()
        if kid in self._keys:
            return self._keys[kid]

        # An unknown kid usually means a rotation. Refetch — but at most once per
        # cooldown, so forged kids cannot drive outbound traffic.
        last = self._last_miss_refresh
        if last is None or self._now() - last > UNKNOWN_KID_COOLDOWN_SECONDS:
            self._last_miss_refresh = self._now()
            self._refresh()
        return self._keys.get(kid)

    def user_id(self, authorization: str | None) -> str:
        """The verified caller's id, or a 401. Never returns an unverified value."""
        if not authorization:
            raise _unauthorized("no authorization header")
        scheme, _, token = authorization.partition(" ")
        if scheme.lower() != "bearer" or not token.strip():
            raise _unauthorized("authorization header is not a bearer token")

        try:
            kid = jwt.get_unverified_header(token).get("kid")
        except jwt.PyJWTError:
            raise _unauthorized("malformed token header") from None
        if not kid:
            raise _unauthorized("token header carries no kid")

        key = self._key_for(kid)
        if key is None:
            raise _unauthorized(f"no published key for kid {kid}")

        try:
            claims = jwt.decode(
                token,
                key,
                algorithms=list(ALLOWED_ALGORITHMS),
                audience=self._audience,
                options={"require": ["exp", "sub", "aud"]},
            )
        except jwt.PyJWTError as error:
            raise _unauthorized(f"token rejected: {type(error).__name__}") from None

        subject = claims.get("sub")
        if not subject:
            raise _unauthorized("token carries no subject")
        return str(subject)


_verifier: JwtVerifier | None = None


def get_verifier() -> JwtVerifier:
    """The process-wide verifier, built from settings on first use."""
    global _verifier
    if _verifier is None:
        url = f"{get_settings().supabase_url.rstrip('/')}/auth/v1/.well-known/jwks.json"
        _verifier = JwtVerifier(fetch_jwks=lambda: _fetch_jwks_from(url))
    return _verifier


def current_user_id(authorization: str | None = Header(default=None)) -> str:
    """FastAPI dependency. The ONLY sanctioned way an endpoint learns who is
    calling — never a path, query or body parameter."""
    return get_verifier().user_id(authorization)
