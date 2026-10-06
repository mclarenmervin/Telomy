"""One envelope for every score.

This shape is the contract that closes the dual-math defect. A number is not
useful on its own — the screen, the agent and a clinician all need to know which
model produced it, which range set it graded against, which day it describes,
and what was missing. Carrying that with the value means the app renders rather
than recomputes, which is the whole point.

`inputs_hash` is what makes a stored number reproducible. Recomputing a snapshot
from its own inputs gives byte-identical output, so a model or range change
tomorrow produces a NEW snapshot instead of silently rewriting one someone has
already read.

The `data_quality` vocabulary is deliberately the same as `predictions` uses, so
the narration layer needs no new concepts.
"""

import hashlib
import json
from datetime import date, datetime

FULL = "full"
PARTIAL = "partial"
NONE = "none"


def inputs_hash(inputs: dict) -> str:
    """A stable fingerprint of what produced a score.

    Key order is normalised, or a dict reordering would look like the user's
    data changed.
    """
    payload = json.dumps(inputs, sort_keys=True, separators=(",", ":"), default=str)
    return "sha256:" + hashlib.sha256(payload.encode()).hexdigest()


def _quality(value, missing_inputs) -> str:
    if value is None:
        # A zero readiness and an unknown readiness are different statements.
        return NONE
    return PARTIAL if missing_inputs else FULL


def build_snapshot(
    result,
    *,
    user_id: str,
    kind: str,
    as_of: date,
    timezone: str,
    inputs: dict,
    computed_at: datetime | None = None,
    ranges_version: str | None = None,
) -> dict:
    """The row to upsert, keyed by (user_id, score_kind, as_of_date).

    `result` is any score result carrying `score`, `drivers`, `missing_inputs`
    and `model_version` — readiness today, the rest as they are ported.
    """
    missing = sorted(getattr(result, "missing_inputs", []) or [])
    value = getattr(result, "score", None)

    return {
        "user_id": user_id,
        "score_kind": kind,
        "as_of_date": as_of.isoformat(),
        "value": value,
        "drivers": [
            {
                "name": d.name,
                "score": d.score,
                "weight": d.weight,
                "detail": getattr(d, "detail", ""),
            }
            for d in getattr(result, "drivers", []) or []
        ],
        "missing_inputs": missing,
        "data_quality": _quality(value, missing),
        "model_version": getattr(result, "model_version", None),
        # None rather than a placeholder: readiness grades against personal
        # baselines, not reference ranges, and saying otherwise would be a lie
        # a clinician could act on.
        "ranges_version": ranges_version,
        "timezone": timezone,
        "inputs_hash": inputs_hash(inputs),
        "computed_at": (computed_at or datetime.utcnow()).isoformat(),
    }
