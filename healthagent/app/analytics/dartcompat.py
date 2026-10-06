"""Arithmetic that matches Dart, so a port can be proved identical.

Two differences are silent and would otherwise show up as a score that is one
point out on some days and not others — the hardest kind of parity bug to find.

`round()` — Dart rounds half away from zero; Python rounds half to even. Dart's
2.5 is 3, Python's is 2.

`Duration.inMinutes` — truncates toward zero rather than rounding, so 89 seconds
is 1 minute and -89 seconds is -1.
"""

from datetime import timedelta
from decimal import ROUND_HALF_UP, Decimal


def dart_round(value: float) -> int:
    """Half away from zero, as Dart's num.round() does."""
    return int(Decimal(str(float(value))).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def in_minutes(delta: timedelta) -> int:
    """Whole minutes, truncated toward zero, as Dart's Duration.inMinutes does."""
    seconds = delta.total_seconds()
    return int(seconds / 60)


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def average(values) -> float:
    values = list(values)
    return sum(values) / len(values)
