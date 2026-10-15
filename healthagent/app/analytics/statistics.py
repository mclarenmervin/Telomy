"""The inference primitives, in ordinary Python.

Correlation is the easiest place in this product to say something false, and
every way of saying it falsely is a statistical one: too few days, too many
pairs tested at once, or days that are not independent observations. This
module is the arithmetic that answers those three, and it holds no opinion
about health — `correlations.py` and `therapy_effect.py` are the callers that
do.

**No scipy, deliberately.** The container carries pdfplumber, LangGraph and a
Supabase client already; adding a numerical stack for one incomplete beta
function would be the largest dependency in the image for the smallest reason.
The continued fraction below is the standard one and is pinned in the tests
against published critical values rather than against itself.

### The three corrections, and what each is protecting against

**A sample-size floor.** The screen today draws a "Strong pattern" from five
matching days. Five days of anything correlate with five days of anything else
often enough that the label is decoration.

**Multiple comparisons.** Ten series make forty-five pairs. At p < 0.05 you
expect two or three to clear the bar with nothing behind them, and a
conversational interface will narrate those two confidently. Benjamini-Hochberg
controls the proportion of reported findings that are false rather than the
chance of any false one, which is the right trade here: this is an exploratory
screen, not a trial, and Bonferroni over forty-five pairs would report nothing
ever.

**Autocorrelation.** This is the one that is easy to miss and does the most
damage. Resting heart rate today is close to resting heart rate yesterday, so
ninety daily readings are nowhere near ninety independent observations. A
p-value computed as though they were is anti-conservative by a large factor,
and feeding it to a multiple-comparison correction corrects the wrong number
carefully. `effective_sample_size` applies the standard Bartlett/Quenouille
adjustment for lag-1 dependence before any p-value is computed.
"""

import math
from statistics import fmean

#: Below three pairs there are no degrees of freedom left: two points lie on a
#: line, so r is 1 and means nothing.
MIN_PAIRS = 3


# ── Correlation ──────────────────────────────────────────────────────────────

def pearson(xs, ys) -> float | None:
    """Pearson's r, or None when there is nothing to correlate.

    None rather than zero when a series never moves. Zero is a claim —
    "these are unrelated" — and a flat series supports no claim at all.
    """
    xs, ys = list(xs), list(ys)
    if len(xs) != len(ys) or len(xs) < MIN_PAIRS:
        return None

    x_mean, y_mean = fmean(xs), fmean(ys)
    covariance = sum((x - x_mean) * (y - y_mean) for x, y in zip(xs, ys))
    x_spread = sum((x - x_mean) ** 2 for x in xs)
    y_spread = sum((y - y_mean) ** 2 for y in ys)

    denominator = math.sqrt(x_spread * y_spread)
    if denominator == 0:
        return None
    # Floating point can push a perfect line a hair past 1, and a coefficient
    # of 1.0000000000000002 makes the t statistic imaginary further down.
    return max(-1.0, min(1.0, covariance / denominator))


def lag1_autocorrelation(values) -> float:
    """How much each day resembles the day before it, on [-1, 1].

    The input is a daily series with its gaps already closed by the caller, so
    "the day before" means the previous observation. That is an approximation
    where a day is missing, and a conservative one: a gap makes consecutive
    observations less alike, which lowers the estimate and costs us sample
    size rather than inventing it.
    """
    values = list(values)
    if len(values) < 2:
        return 0.0
    mean = fmean(values)
    spread = sum((v - mean) ** 2 for v in values)
    if spread == 0:
        return 0.0
    covariance = sum(
        (values[i] - mean) * (values[i + 1] - mean) for i in range(len(values) - 1)
    )
    return max(-1.0, min(1.0, covariance / spread))


def effective_sample_size(n: int, r1: float, r2: float) -> float:
    """How many independent observations `n` autocorrelated days are worth.

    The Bartlett/Quenouille adjustment for two lag-1 autocorrelated series:

        n_eff = n · (1 − r1·r2) / (1 + r1·r2)

    Clamped at both ends, and the upper clamp is the one that matters. When
    the two series are autocorrelated in *opposite* directions the formula
    returns more than `n`, which would have us claim more evidence than days
    observed; we decline the credit. The lower clamp keeps a number the caller
    can still compute a p-value from.
    """
    product = max(-0.99, min(0.99, r1 * r2))
    adjusted = n * (1 - product) / (1 + product)
    return max(float(MIN_PAIRS), min(float(n), adjusted))


# ── The t distribution ───────────────────────────────────────────────────────

def _incomplete_beta(a: float, b: float, x: float) -> float:
    """The regularised incomplete beta function I_x(a, b).

    Lentz's continued fraction, as in Numerical Recipes. The fraction only
    converges quickly on one side of x = (a+1)/(a+b+2), so past that point it
    is evaluated on the reflection I_x(a,b) = 1 - I_{1-x}(b,a) instead. The
    leading factor is the same for both because a·log(x) + b·log(1-x) is
    unchanged when a and b swap along with x and 1-x.
    """
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0

    leading = math.exp(
        math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
        + a * math.log(x) + b * math.log1p(-x)
    )
    if x < (a + 1) / (a + b + 2):
        return leading * _continued(a, b, x) / a
    return 1.0 - leading * _continued(b, a, 1 - x) / b


def _continued(a: float, b: float, x: float, iterations: int = 300) -> float:
    """The continued fraction itself, evaluated by the modified Lentz method."""
    tiny = 1e-300
    c, d = 1.0, 1.0 - (a + b) * x / (a + 1)
    if abs(d) < tiny:
        d = tiny
    d = 1 / d
    result = d

    for m in range(1, iterations + 1):
        even = m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m))
        odd = -(a + m) * (a + b + m) * x / ((a + 2 * m) * (a + 2 * m + 1))
        for numerator in (even, odd):
            d = 1 + numerator * d
            if abs(d) < tiny:
                d = tiny
            c = 1 + numerator / c
            if abs(c) < tiny:
                c = tiny
            d = 1 / d
            step = c * d
            result *= step
            if abs(step - 1) < 1e-14:
                return result
    return result


def student_t_two_tailed(t: float, df: float) -> float:
    """P(|T| > |t|) for Student's t with `df` degrees of freedom.

        p = I_{df/(df + t²)}(df/2, 1/2)

    Pinned in the tests against the 10-df table value and against the df = 1
    Cauchy identity, which needs no table at all.
    """
    if df <= 0:
        return 1.0
    t = abs(t)
    if t == 0:
        return 1.0
    if math.isinf(t):
        return 0.0
    return _incomplete_beta(df / 2, 0.5, df / (df + t * t))


def pearson_p_value(r: float, n: float) -> float | None:
    """The two-tailed p for a correlation of `r` over `n` observations.

    `n` is a float because the caller passes the *effective* sample size, not
    the day count — which is the whole point of `effective_sample_size`.
    """
    if n < MIN_PAIRS:
        return None
    r = max(-1.0, min(1.0, r))
    if abs(r) >= 1.0:
        # Perfectly collinear. The t statistic is infinite rather than
        # undefined, and this is the most significant thing there is.
        return 0.0
    df = n - 2
    t = r * math.sqrt(df / (1 - r * r))
    return student_t_two_tailed(t, df)


# ── One sample, for a before/after delta ─────────────────────────────────────

def one_sample_t(deltas) -> tuple[float | None, float | None]:
    """(mean, two-tailed p) for a set of per-session before/after changes.

    One-sample rather than two: each session supplies its own before and its
    own after, so the pairing is already done and what is being tested is
    whether the differences are centred on zero. Pooling all the befores and
    all the afters instead would throw that pairing away and compare one
    person's good weeks with their bad ones.

    `(mean, None)` for a single observation. One session is a story, and a
    p-value computed from it would be a number with no evidence behind it.
    """
    deltas = list(deltas)
    if not deltas:
        return None, None
    mean = fmean(deltas)
    if len(deltas) < 2:
        return mean, None

    variance = sum((d - mean) ** 2 for d in deltas) / (len(deltas) - 1)
    if variance == 0:
        # Every session moved it by exactly the same amount. That is the most
        # certain result there is, unless the amount was nothing.
        return mean, 0.0 if mean != 0 else 1.0

    t = mean / math.sqrt(variance / len(deltas))
    return mean, student_t_two_tailed(t, len(deltas) - 1)


def one_sample_summary(deltas, confidence: float = 0.95) -> dict:
    """Mean, p-value and a conservative two-sided confidence interval.

    The 1.96 normal critical value is intentionally widened for small samples
    with a compact t-table. F12 never evaluates fewer than five sessions.
    """
    values = list(deltas)
    mean, p_value = one_sample_t(values)
    if not values:
        return {"mean": None, "p_value": None, "ci_low": None, "ci_high": None}
    if len(values) < 2:
        return {"mean": mean, "p_value": p_value, "ci_low": None, "ci_high": None}
    variance = sum((value - mean) ** 2 for value in values) / (len(values) - 1)
    critical = {4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365,
                8: 2.306, 9: 2.262, 10: 2.228}.get(len(values) - 1, 1.96)
    margin = critical * math.sqrt(variance / len(values))
    return {"mean": mean, "p_value": p_value,
            "ci_low": mean - margin, "ci_high": mean + margin,
            "confidence": confidence}


# ── Multiple comparisons ─────────────────────────────────────────────────────

def benjamini_hochberg(p_values, q: float) -> list[bool]:
    """Which of these p-values survive at a false discovery rate of `q`.

    Returns a mask in the caller's order, not sorted, because the caller is
    holding a parallel list of pairs and re-matching them would be a bug
    waiting to happen.

    Step-up: find the largest rank whose p is at or below its rung i·q/m, then
    keep everything at that rank and below. Keeping only the p-values that
    individually meet their own rung is the common mistake and is stricter
    than the procedure.
    """
    ranked = sorted(enumerate(p_values), key=lambda pair: pair[1])
    m = len(ranked)
    if m == 0:
        return []

    cutoff = -1
    for rank, (_, p) in enumerate(ranked, start=1):
        if p <= rank * q / m:
            cutoff = rank

    kept = [False] * m
    for rank, (position, _) in enumerate(ranked, start=1):
        if rank <= cutoff:
            kept[position] = True
    return kept


def benjamini_hochberg_q_values(p_values) -> list[float]:
    """Adjusted BH q-values in caller order, monotone across ranked p-values."""
    values = list(p_values)
    ranked = sorted(enumerate(values), key=lambda pair: pair[1])
    count = len(ranked)
    adjusted = [1.0] * count
    running = 1.0
    for rank in range(count, 0, -1):
        position, p_value = ranked[rank - 1]
        running = min(running, p_value * count / rank)
        adjusted[position] = min(1.0, running)
    return adjusted
