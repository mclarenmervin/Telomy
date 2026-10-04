"""The predictions.kind constraint must accept every kind the code writes.

Each migration that touches it drops and recreates it, so a migration that
forgets an existing kind either fails to apply (rows present) or breaks that
writer at runtime (table empty). No Python test catches that by exercising the
agents, because none of them talks to a real Postgres — so the constraint is
checked against the kinds the source actually persists.
"""

import re
from pathlib import Path

from app.analytics.check_in import PRIORITY, CHECK_IN_PREFIX

DB = Path(__file__).resolve().parents[1] / "db"

# Every literal passed as predictions.kind anywhere in app/, plus the check-in
# kinds built from the reason constants.
KINDS_WRITTEN = ["ack", "analysis", "activity_summary"] + [
    f"{CHECK_IN_PREFIX}{reason}" for reason in PRIORITY
]


def _latest_kind_constraint() -> str:
    """The body of the last `add constraint predictions_kind_check` in db/."""
    bodies = []
    for path in sorted(DB.glob("*.sql")):
        bodies += re.findall(
            r"add constraint predictions_kind_check\s+check\s*\((.*?)\);",
            path.read_text(),
            re.S | re.I,
        )
    assert bodies, "no predictions_kind_check constraint found in db/"
    return bodies[-1]


def _allows(constraint: str, kind: str) -> bool:
    """Evaluate the two clause shapes the constraint uses: an IN list and a regex."""
    in_list = re.search(r"kind in \((.*?)\)", constraint, re.S | re.I)
    allowed = (
        {v.strip().strip("'") for v in in_list.group(1).split(",")} if in_list else set()
    )
    if kind in allowed:
        return True
    return any(
        re.match(pattern, kind)
        for pattern in re.findall(r"kind ~ '([^']+)'", constraint)
    )


def test_the_latest_constraint_accepts_every_kind_the_code_writes():
    constraint = _latest_kind_constraint()

    rejected = [kind for kind in KINDS_WRITTEN if not _allows(constraint, kind)]

    assert rejected == [], (
        f"predictions.kind constraint would reject {rejected}; a migration that "
        f"drops an in-use kind aborts on a populated table and breaks that writer "
        f"on an empty one. Constraint: {constraint.strip()}"
    )


def test_the_constraint_still_rejects_an_unknown_kind():
    constraint = _latest_kind_constraint()

    assert not _allows(constraint, "whatever")
    assert not _allows(constraint, "check_in:")
    assert not _allows(constraint, "check_in:Mixed-Case")
