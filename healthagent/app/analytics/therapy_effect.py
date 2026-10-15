"""What a person's own therapy sessions actually do to them.

Today a sauna is a journal entry with a free-text note in it. This turns a run
of them into before/after evidence: for each session, the hour after against
the hour before; then, across sessions, whether those differences are centred
on zero.

**The person is their own control, so no baseline is needed.** Each session
supplies both of its own numbers, and measuring each against a fortnight
baseline and then subtracting would cancel it exactly:
(after - baseline) - (before - baseline) is after - before. That is not only
tidier, it is what makes the feature affordable — only the two hours around
each session have to be read, rather than a fortnight of a wearable's stream
per session.

**It aggregates `event_analysis`, it does not reimplement it.** One session's
before/during/after windows, its baseline, and the exclusion of other events
from that baseline are already decided there, and a second copy of those
windows would drift from the one the activity report narrates.

### The four ways of being wrong, and what refuses each

**One session is a story.** A single sauna followed by a good night is the
most persuasive and least informative thing in wellness. There is a floor on
sessions, and a run below it is not entered into the hypothesis set at all —
so it also cannot make the correction harsher for a modality that had enough.

**Too many metrics.** Four tracked signals across four modalities is sixteen
tests, and two or three will clear p < 0.05 with nothing behind them. Only
declared effects are tested, and the false discovery rate is computed over
those.

**No mechanism, or the wrong direction.** `therapies.v1.yaml` says which
signals a modality is expected to move and which way. An effect that is clean
and runs the other way is something else happening around the session.

**The session is not the only thing that happened.** This is the confounder
specific to therapies and it is the one most likely to produce a confident
falsehood: a sauna taken straight after a workout measures the workout. A
session overlapping another logged event is dropped from the run rather than
averaged in, which is the same judgement `analyze_event` already makes about
what may enter a baseline.

### What is still not answered

Everything here is **acute** — the hour after. "Is the sauna making me
fitter?" is a chronic question, runs in the opposite direction for several of
these signals, and is not answerable by this model. Asking an acute model a
chronic question is the obvious way to misuse it, which is why the catalog
says so too.
"""

from datetime import datetime, timedelta

from app.analytics import therapy_catalog
from app.analytics.event_analysis import WINDOW, analyze_event, to_readings
from app.analytics.statistics import (
    benjamini_hochberg,
    benjamini_hochberg_q_values,
    one_sample_summary,
)
from app.analytics.therapy_catalog import INCREASE
from app.common.timeparse import parse_ts

MODEL_VERSION = "therapy-effect-v2"

#: How far back a run may reach. A year of sessions is a fair question;
#: "ever" would compare this winter's sauna with the one in a different flat.
WINDOW_DAYS = 365

#: Below this there is no run, only anecdotes. Five is where a consistent
#: direction stops being plausible by chance alone and is still reachable by
#: somebody who saunas weekly.
MIN_SESSIONS = 5

#: The false discovery rate, matching the correlation engine's for the same
#: reason: this leads to a conversation, not to a treatment.
FDR_Q = 0.10

#: Why a tested effect is not being shown.
TOO_FEW_SESSIONS = "too_few_sessions"
NOT_SIGNIFICANT = "not_significant"
DIRECTION_MISMATCH = "direction_mismatch"
CONFOUNDED = "confounded"
NO_WEARABLE_DATA = "no_wearable_data"

HELPED = "helped"
PROMISING = "promising"
POSSIBLE_NEGATIVE = "possible_negative"
NO_RELIABLE_SIGNAL = "no_reliable_signal"
TOO_EARLY = "too_early"
IN_SESSION_ONLY = "in_session_only"


def _overlaps(start: datetime, end: datetime, other_events) -> bool:
    """Did something else the user logged run across this session?

    The window either side is included, because an event that ended twenty
    minutes before the sauna started is still in the hour this measures.
    """
    return any(
        other_start <= end + WINDOW and start - WINDOW <= other_end
        for other_start, other_end in other_events
    )


def _session_deltas(sessions, readings, other_events) -> dict:
    """Per modality, per metric, one after-minus-before delta per session.

    Within a session, so a week when everything was elevated does not read as
    every session doing nothing: the elevation is in both numbers and cancels.
    That is also why `analyze_event`'s baseline is not consulted here — it
    would cancel too, and the readings for it would be a fortnight of a
    wearable's stream per session.
    """
    deltas: dict[tuple[str, str], list[float]] = {}
    counted: dict[str, int] = {}
    eligible: dict[str, int] = {}
    dropped: dict[str, int] = {}

    for raw in sessions:
        start, end = parse_ts(raw.get("started_at")), parse_ts(raw.get("ended_at"))
        if start is None or end is None or end <= start:
            # A session still running has no "after" yet.
            continue

        modality = therapy_catalog.modality_for_event(raw.get("event_type"))
        if modality is None:
            continue

        if _overlaps(start, end, other_events):
            # A sauna straight after a workout measures the workout.
            dropped[modality.id] = dropped.get(modality.id, 0) + 1
            continue

        eligible[modality.id] = eligible.get(modality.id, 0) + 1

        analysis = analyze_event(readings, start, end, other_events)
        used = False
        for effect in modality.effects:
            metric = analysis["metrics"].get(effect.metric) or {}
            before, after = metric.get("before_mean"), metric.get("after_mean")
            if before is None or after is None:
                continue
            deltas.setdefault((modality.id, effect.metric), []).append(after - before)
            used = True
        if used:
            counted[modality.id] = counted.get(modality.id, 0) + 1

    return {"deltas": deltas, "counted": counted, "eligible": eligible, "dropped": dropped}


def _matches_direction(expect: str, mean_delta: float) -> bool:
    return (expect == INCREASE and mean_delta > 0) or (
        expect != INCREASE and mean_delta < 0
    )


def _replicates(values, expect: str) -> bool:
    """Chronological split-half direction agreement; never language-inferred."""
    values = list(values)
    midpoint = len(values) // 2
    if midpoint < 2 or len(values) - midpoint < 2:
        return False
    first = sum(values[:midpoint]) / midpoint
    second = sum(values[midpoint:]) / (len(values) - midpoint)
    return _matches_direction(expect, first) and _matches_direction(expect, second)


def classify_verdict(values, expect: str, q_value: float | None = None) -> dict:
    """Six-state reversible classification over one declared outcome."""
    values = list(values)
    if not values:
        return {"verdict": IN_SESSION_ONLY, "summary": one_sample_summary([]),
                "replicated": False}
    if len(values) < MIN_SESSIONS:
        return {"verdict": TOO_EARLY, "summary": one_sample_summary(values),
                "replicated": False}
    summary = one_sample_summary(values)
    mean = summary["mean"]
    beneficial = _matches_direction(expect, mean)
    replicated = _replicates(values, expect)
    excludes_zero = summary["ci_low"] is not None and (
        summary["ci_low"] > 0 or summary["ci_high"] < 0
    )
    raw_signal = summary["p_value"] is not None and summary["p_value"] < 0.01 and excludes_zero
    if beneficial and raw_signal and q_value is not None and q_value <= FDR_Q and replicated:
        verdict = HELPED
    elif beneficial and raw_signal:
        verdict = PROMISING
    elif not beneficial and excludes_zero and summary["p_value"] is not None and summary["p_value"] < 0.05:
        verdict = POSSIBLE_NEGATIVE
    else:
        verdict = NO_RELIABLE_SIGNAL
    return {"verdict": verdict, "summary": summary, "replicated": replicated}


def effects_for(sessions, readings, other_events=(), path=None) -> dict:
    """Every declared effect, tested against this person's sessions."""
    gathered = _session_deltas(sessions, readings, other_events)
    deltas = gathered["deltas"]

    candidates = []
    _, modalities = therapy_catalog.load_modalities(path)

    for modality in sorted(modalities.values(), key=lambda m: m.id):
        for effect in modality.effects:
            eligible = gathered["eligible"].get(modality.id, 0)
            if eligible == 0:
                continue
            observed = deltas.get((modality.id, effect.metric), [])
            summary = one_sample_summary(observed)
            candidates.append((modality, effect, observed, summary))

    tested_indexes = [index for index, candidate in enumerate(candidates)
                      if len(candidate[2]) >= MIN_SESSIONS and candidate[3]["p_value"] is not None]
    q_values = benjamini_hochberg_q_values([candidates[index][3]["p_value"] for index in tested_indexes])
    q_by_index = dict(zip(tested_indexes, q_values))

    verdicts, reported, withheld = [], [], []
    for index, (modality, effect, observed, _summary) in enumerate(candidates):
        classification = classify_verdict(observed, effect.expect, q_by_index.get(index))
        verdict = classification["verdict"]
        if verdict == TOO_EARLY:
            reason = TOO_FEW_SESSIONS
        elif verdict == IN_SESSION_ONLY:
            reason = NO_WEARABLE_DATA
        elif verdict == NO_RELIABLE_SIGNAL:
            reason = NOT_SIGNIFICANT
        elif verdict == POSSIBLE_NEGATIVE:
            reason = DIRECTION_MISMATCH
        else:
            reason = None
        row = _row(modality, effect, observed, classification, q_by_index.get(index),
                   reason, gathered, path)
        verdicts.append(row)
        (withheld if reason else reported).append(row)

    reported.sort(key=lambda r: abs(r["mean_delta"] or 0), reverse=True)
    withheld.sort(key=lambda r: (r["modality"], r["metric"]))

    return {
        "model_version": MODEL_VERSION,
        "catalog_version": therapy_catalog.catalog_version(path),
        "window_days": WINDOW_DAYS,
        "fdr_q": FDR_Q,
        "min_sessions": MIN_SESSIONS,
        "tested": len(tested_indexes),
        "verdicts": verdicts,
        "reported": reported,
        "withheld": withheld,
    }


def _row(modality, effect, observed, classification, q_value, withheld_reason,
         gathered, path) -> dict:
    summary = classification["summary"]
    sessions = len(observed)
    mean_delta = summary["mean"]
    p_value = summary["p_value"]
    review = (
        therapy_catalog.review_status(modality.id, effect.metric, path)
        if withheld_reason is None
        else None
    )
    reviewed = bool(review and review.reviewed)
    return {
        "modality": modality.id,
        "label": modality.label,
        "metric": effect.metric,
        "mean_delta": mean_delta,
        "sessions": sessions,
        # Sessions thrown out because something else was happening. Reported
        # rather than hidden: "we had nine and used seven" is the difference
        # between a thin result and a broken one.
        "sessions_confounded": gathered["dropped"].get(modality.id, 0),
        "p_value": p_value,
        "q_value": q_value,
        "ci_low": summary["ci_low"],
        "ci_high": summary["ci_high"],
        "replicated": classification["replicated"],
        "verdict": classification["verdict"],
        "wearable_coverage": sessions / gathered["eligible"].get(modality.id, sessions or 1),
        "next_milestone": _next_milestone(classification["verdict"], sessions),
        "provenance": {"model_version": MODEL_VERSION, "catalogue_modality": modality.id},
        "expected_direction": effect.expect,
        "mechanism": effect.mechanism if reviewed else None,
        "citation": effect.citation if reviewed else None,
        "mechanism_reviewed": reviewed,
        "reviewer": review.reviewer if reviewed else None,
        "withheld": withheld_reason,
    }


def _next_milestone(verdict: str, sessions: int) -> str:
    if verdict in (IN_SESSION_ONLY, TOO_EARLY):
        return f"Complete {max(0, MIN_SESSIONS - sessions)} more eligible sessions with wearable coverage."
    if verdict == PROMISING:
        return "Repeat the pattern in both halves of a longer run."
    if verdict == POSSIBLE_NEGATIVE:
        return "Discuss the adverse pattern with your care team before continuing."
    if verdict == NO_RELIABLE_SIGNAL:
        return "More consistent sessions may clarify whether a repeatable signal exists."
    return "Keep recording sessions to confirm the pattern remains stable."


# ── The seam: one implementation, two callers ────────────────────────────────

#: How many sessions one run may analyse, newest first.
#:
#: A cap rather than a page, because the cost is one narrow reading query per
#: session: twenty is about two seconds of round trips, which an interactive
#: screen and a chat turn can both afford, and two hundred is not. Somebody
#: with two hundred sauna sessions gets their most recent twenty, which is
#: also the more honest answer -- a run that reaches back three years is
#: comparing this winter with a different flat.
#:
#: If this ever needs to be larger, the fix is a stored snapshot computed off
#: the request path, not a longer timeout.
MAX_SESSIONS = 20


def for_user(loader, user_id: str, days: int = WINDOW_DAYS, path=None) -> dict:
    """This person's therapy evidence, as both the endpoint and the tool see it."""
    _, modalities = therapy_catalog.load_modalities(path)
    event_types = sorted(
        {event_type for m in modalities.values() for event_type in m.event_types}
    )

    sessions = loader.therapy_sessions(
        user_id, event_types, days=days, limit=MAX_SESSIONS
    )["items"]
    if not sessions:
        return effects_for([], [], path=path)

    readings, other_events = [], []
    seen_readings = set()
    for raw in sessions:
        start, end = parse_ts(raw.get("started_at")), parse_ts(raw.get("ended_at"))
        if start is None or end is None:
            continue
        rows = loader.readings_between(
            user_id, (start - WINDOW).isoformat(), (end + WINDOW).isoformat()
        )
        for row in rows:
            # Sessions close together ask for overlapping spans; a reading
            # counted twice would halve the weight of the other readings in
            # the same window.
            key = (row.get("measurement_type"), row.get("recorded_at"), row.get("value"))
            if key in seen_readings:
                continue
            seen_readings.add(key)
            readings.append(row)

    # What else the user logged around these sessions. A sauna straight after
    # a workout measures the workout.
    span_start = min(parse_ts(s["started_at"]) for s in sessions)
    other_events = loader.events_between(
        user_id,
        (span_start - WINDOW).isoformat(),
        exclude_types=event_types,
    )

    return effects_for(sessions, to_readings(readings), other_events, path=path)
