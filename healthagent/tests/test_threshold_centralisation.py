"""Spec 5.1: thresholds live in app/common/thresholds.py only.

A second hardcoded copy means tuning the env moves one consumer and not the other,
so the warning and the escalation can disagree about the same reading.
"""

import re
from pathlib import Path

APP = Path(__file__).resolve().parent.parent / "app"

# The numbers thresholds.py owns. A bare literal equal to one of these, assigned to a
# module-level constant outside thresholds.py, is almost certainly a duplicated copy.
OWNED = {"90.0", "95.0", "200.0", "15.0"}
ASSIGNMENT = re.compile(r"^([A-Z][A-Z0-9_]*)\s*=\s*([0-9]+\.[0-9]+)\s*(?:#.*)?$", re.M)


def test_no_module_redeclares_a_threshold_thresholds_py_owns():
    offenders = []
    for path in APP.rglob("*.py"):
        if path.name == "thresholds.py":
            continue
        for name, value in ASSIGNMENT.findall(path.read_text()):
            if value in OWNED:
                offenders.append(f"{path.relative_to(APP)}:{name} = {value}")

    assert offenders == [], (
        "these duplicate a value thresholds.py owns; read it from there instead: "
        + ", ".join(offenders)
    )
