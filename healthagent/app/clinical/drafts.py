"""Turning a finding into something a clinician can sign.

`marker_trends` decides *whether* a human should look. This decides what they
are shown. The split matters: one is arithmetic over values, the other is a
sentence and a routing decision, and the second is where the care about wording
has to live.

### The body states arithmetic, not meaning

"HbA1c has risen 11.1%, from 5.4% to 6.0%" is a fact about two numbers.
"Your HbA1c is high" is a clinical claim, sourced from a catalog that says in
capitals that it has not been reviewed by a clinician. So the agent writes the
first and the clinician writes the second -- which is what `revised` is for in
the state machine, and is the actual division of labour this phase buys.

It is also why a trend draft carries no routing flags and is therefore eligible
for the SLA path: if the queue stalls, a statement of arithmetic can still
reach the user unreviewed, where a recommendation never can.

### A draft never stands in front of an escalation

A haemoglobin of 4.1 goes to `lab_escalations` immediately, deterministically,
and independently of any review state. If the same value could also produce a
draft, the review queue would be standing between a person and an emergency.
So a critical *latest* value produces no draft at all -- judged on the latest
value only, because "is this an emergency now" is a question about the newest
result, and a marker that was critical a year ago and has recovered is exactly
the trend a clinician would want to see.
"""

from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone

from app.agent.guardrails import CLINICIAN_QUEUE, apply_guardrails
from app.analytics import catalog
from app.analytics.marker_trends import (
    MODEL_VERSION,
    RISING,
    MarkerTrend,
    find_trends,
)
from app.analytics.reference_ranges import is_critical
from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)

#: A trend in a lab marker is a lab finding. `observation` is for the wearable
#: and event side, which F6 and F8 add.
DRAFT_KIND = "lab_finding"

#: How long a draft waits for a human before the SLA sweep takes over. The
#: plan's de-risk for "the clinician queue becomes the bottleneck and the
#: product feels dead" -- long enough that a clinician working daily always
#: gets first refusal, short enough that a stalled queue does not mean silence.
SLA_HOURS = 72


@dataclass(frozen=True)
class DraftCandidate:
    """A draft that has not been written to the database yet.

    Separated from the row so the wording and the routing can be tested without
    a database, and so the caller decides the clinic and the deadline.
    """

    user_id: str
    kind: str
    title: str
    body: str
    dedupe_key: str
    evidence: list[dict] = field(default_factory=list)
    routing_flags: list[str] = field(default_factory=list)
    model_version: str = MODEL_VERSION
    source_kind: str | None = None
    source_id: str | None = None

    def row(self, *, clinic_id: str | None, sla_due_at: str) -> dict:
        return {
            "user_id": self.user_id,
            "clinic_id": clinic_id,
            "kind": self.kind,
            "title": self.title,
            "body": self.body,
            "evidence": self.evidence,
            "routing_flags": self.routing_flags,
            "model_version": self.model_version,
            "source_kind": self.source_kind,
            "source_id": self.source_id,
            "dedupe_key": self.dedupe_key,
            "sla_due_at": sla_due_at,
            # Stated rather than left to the default, because the state machine
            # refuses anything else on insert and an explicit value makes that
            # a deliberate agreement rather than a coincidence.
            "status": "drafted",
        }


def _quantity(value: float, unit: str) -> str:
    """A number with its unit, printed the way a report prints it.

    "5.4 %" is not how a lab prints a percentage and "12.4g/dL" is not how it
    prints a concentration. F4 shipped "Rdw" and "Hs crp" to a real screen with
    every test green, so the small typography is tested here too.
    """
    text = f"{value:g}"
    if "." not in text and unit == "%":
        # 6 reads as a count; 6.0% reads as a measurement. Only for percentages,
        # where a single significant figure is the common case.
        text = f"{value:.1f}"
    return f"{text}{unit}" if unit == "%" else f"{text} {unit}"


def _printed_date(value: date) -> str:
    # No zero padding: "1 February 2026", as a person would write it.
    return f"{value.day} {value.strftime('%B %Y')}"


def _marker_name(biomarker_id: str) -> str:
    """The printed name from the catalog, never a title-cased id.

    This is the F4 bug in one line: `biomarker_id.title()` turns `rdw` into
    "Rdw" and `hs_crp` into "Hs crp", and both looked fine in every test until
    they were on a screen.
    """
    marker = catalog.get(biomarker_id)
    return marker.name if marker else biomarker_id


def _context_suffix(context: str) -> str:
    """"(fasting)" after a marker whose context changes what it means.

    Without it a fasting and a post-prandial glucose trend are two drafts with
    the same title, and a clinician has to open both to tell them apart.
    """
    if context in ("", "standard"):
        return ""
    return f" ({context.replace('_', '-')})"


def draft_for_trend(trend: MarkerTrend, user_id: str) -> DraftCandidate | None:
    """One trend as a draft, or None if it must not become one.

    None means the escalation path owns this value and a queue must not be put
    in front of it.
    """
    latest = trend.latest
    if is_critical(trend.biomarker_id, latest.value_canonical):
        # Deliberately not "draft it and mark it urgent". A critical value is
        # already an escalation, written before the user confirmed anything and
        # independent of review state; a second artefact about the same number
        # would either duplicate the alarm or, worse, look like the response to
        # it while waiting in a queue.
        logger.info(
            f"no draft for a critical value {log_context(user_id=user_id)} "
            f"marker={trend.biomarker_id} value={latest.value_canonical}"
        )
        return None

    name = _marker_name(trend.biomarker_id) + _context_suffix(trend.context)
    moved = "risen" if trend.direction == RISING else "fallen"
    first = trend.first

    title = f"{name} has {moved} across {len(trend.points)} results"
    body = (
        f"{name} has {moved} {abs(trend.relative_change) * 100:.1f}% across "
        f"{len(trend.points)} results, from "
        f"{_quantity(first.value_canonical, first.unit_canonical)} on "
        f"{_printed_date(first.collected_at)} to "
        f"{_quantity(latest.value_canonical, latest.unit_canonical)} on "
        f"{_printed_date(latest.collected_at)}."
    )

    # Run through the guardrail rather than trusted to be safe. The flags are
    # whatever the clinician profile says they are -- not recomputed here with a
    # second set of rules, because if the two disagreed about what counts as
    # medication content a draft could reach a user unflagged carrying text the
    # autonomous profile would have replaced.
    body, flags = apply_guardrails(body, {"metrics": {}}, profile=CLINICIAN_QUEUE)

    return DraftCandidate(
        user_id=user_id,
        kind=DRAFT_KIND,
        title=title,
        body=body,
        # The marker, the context and the latest draw -- what was noticed, not
        # when we noticed it.
        dedupe_key=(
            f"trend:{trend.biomarker_id}:{trend.context}:{trend.as_of.isoformat()}"
        ),
        evidence=[
            {
                "biomarker_id": point.biomarker_id,
                "value_canonical": point.value_canonical,
                "unit_canonical": point.unit_canonical,
                # isoformat, not a date object: this lands in a jsonb column and
                # a date would raise at insert time on the nightly sweep, where
                # nobody is watching.
                "collected_at": point.collected_at.isoformat(),
                "context": point.context,
                "lab_name": point.lab_name,
            }
            for point in trend.points
        ],
        routing_flags=flags,
        source_kind="biomarker_trend",
    )


def trend_drafts(rows, user_id: str, as_of: date) -> list[DraftCandidate]:
    """Every draft this user's confirmed results currently justify.

    `rows` are `biomarker_results` records as `ContextLoader.biomarker_results`
    returns them -- already filtered to `confirmed` and `corrected`, because a
    value a machine read and nobody checked must not put something in front of
    a clinician either.
    """
    candidates = []
    for trend in find_trends(rows, as_of=as_of):
        candidate = draft_for_trend(trend, user_id=user_id)
        if candidate is not None:
            candidates.append(candidate)
    return candidates


def _existing_keys(supabase, user_id: str, keys: list[str]) -> set[str]:
    if not keys:
        return set()
    rows = (
        supabase.table("clinical_drafts")
        .select("dedupe_key")
        .eq("user_id", user_id)
        .in_("dedupe_key", keys)
        .execute()
        .data
    )
    return {row["dedupe_key"] for row in rows or []}


def create_drafts(
    supabase,
    user_id: str,
    candidates: list[DraftCandidate],
    *,
    clinic_id: str | None = None,
    now: datetime | None = None,
) -> list[dict]:
    """Write the drafts that do not already exist. Returns the rows created.

    Checked before inserting rather than relying on the constraint alone,
    because `one_draft_per_finding` would make the whole statement fail rather
    than skipping the duplicate -- and a sweep that aborts on the first
    already-seen finding never reaches the new one. The constraint remains the
    guarantee for two sweeps racing.

    `clinic_id` of None is the Bonphul network pool, which any clinician in
    good standing may claim. A user not enrolled with a clinic still gets
    reviewed.
    """
    if not candidates:
        return []

    now = now or datetime.now(timezone.utc)
    sla_due_at = (now + timedelta(hours=SLA_HOURS)).isoformat()
    seen = _existing_keys(supabase, user_id, [c.dedupe_key for c in candidates])

    rows = [
        c.row(clinic_id=clinic_id, sla_due_at=sla_due_at)
        for c in candidates
        if c.dedupe_key not in seen
    ]
    if not rows:
        return []

    created = supabase.table("clinical_drafts").insert(rows).execute().data
    logger.info(
        f"clinical drafts created {log_context(user_id=user_id)} "
        f"count={len(rows)} skipped={len(candidates) - len(rows)}"
    )
    return created or []
