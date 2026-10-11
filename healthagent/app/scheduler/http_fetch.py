"""The one outbound HTTP call this product makes to a third party.

In its own module, two dozen lines, so that "what does Telomy send to anybody
else" has an answer somebody can read in a minute. Everything else that leaves
this system goes to Supabase, Redis or a model provider under our own account.

It is injected into the sweep rather than imported by it, which is what lets
the whole scheduler be tested without a socket and what makes switching this
off a matter of not passing it.
"""

import json
import urllib.parse
import urllib.request

from app.common.logging_config import get_logger

logger = get_logger(__name__)

#: Short. A scheduler tick must not hang on somebody else's outage, and a
#: night without snapshots is a tolerable outcome.
TIMEOUT_SECONDS = 20

#: Identifies us honestly rather than pretending to be a browser. Open-Meteo
#: asks for attribution and this is the cheapest half of it.
USER_AGENT = "Telomy/1.0 (health platform; environment context)"


def fetch_json(url: str, params: dict) -> dict:
    """GET and decode. Raises on anything that is not a JSON object.

    No identifier of any kind is added here, and none is accepted: the only
    thing that reaches the provider is the coarse coordinate the caller put
    in `params`.
    """
    query = urllib.parse.urlencode(params)
    request = urllib.request.Request(
        f"{url}?{query}", headers={"User-Agent": USER_AGENT}
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:  # noqa: S310
        payload = json.loads(response.read())
    if not isinstance(payload, dict):
        raise ValueError("the provider did not return an object")
    return payload
