"""The user-scoped data tools, shared by every agent that reads a person's data.

One implementation, three callers: the activity agent narrating a finished
session, the concierge answering a question, and — through the loader
underneath — the REST endpoints the app renders from. If these ever became two
implementations, a chart, a report and a conversation would start disagreeing
about the same user, which is the defect this layer exists to close.

Two invariants, both load-bearing and both tested:
  * no tool takes an identity argument — `user_id` comes from the runtime
    context, so cross-tenant access is impossible by construction rather than
    by remembering to filter
  * every model-supplied number is clamped before it reaches a query

Nothing here reads `clinical_drafts`. The database has no user-facing select
policy on that table, which protects the phone and the console but not us: the
agent holds service-role credentials and bypasses RLS by design. The
enforcement on our side is this absence.
"""

from dataclasses import dataclass

from langchain.tools import ToolRuntime, tool

from app.analytics import correlations, therapy_effect

MAX_DAYS = 365
MAX_LIMIT = 50


@dataclass(frozen=True)
class UserScope:
    """All a data tool needs from its runtime: who is asking.

    Declared here rather than imported from one agent, so neither agent's
    context is the other's dependency. Every real context — `ActivityContext`,
    `ConciergeContext` — satisfies it, and a tool that needed more than this
    field would be a tool that belongs to one caller rather than to all of
    them.
    """

    user_id: str


def clamp(value, low: int, high: int) -> int:
    try:
        value = int(value)
    except (TypeError, ValueError):
        return low
    return max(low, min(high, value))


def build_data_tools(loader) -> list:
    @tool
    def get_past_sessions(
        runtime: ToolRuntime[UserScope],
        activity_type: str | None = None,
        limit: int = 5,
        window_days: int = 90,
    ) -> dict:
        """Aggregated past activity sessions for the current user.

        Pass activity_type=None to span all activity types. Never returns raw samples.
        """
        return loader.past_activity_sessions(
            runtime.context.user_id,
            activity_type,
            limit=clamp(limit, 1, MAX_LIMIT),
            window_days=clamp(window_days, 1, MAX_DAYS),
        )

    @tool
    def get_logs(
        runtime: ToolRuntime[UserScope],
        kind: str,
        days: int = 30,
        limit: int = 20,
    ) -> dict:
        """Entries the user logged, by kind.

        kind is one of: lab_results, therapy_sessions, genetic_records, environment_logs,
        meals, workouts, hydration_logs, plans, progress_checkins, consultations,
        timeline_events. Use this to explain a session from what happened around it.
        """
        try:
            return loader.logs(
                runtime.context.user_id,
                kind,
                days=clamp(days, 1, MAX_DAYS),
                limit=clamp(limit, 1, MAX_LIMIT),
            )
        except ValueError as exc:
            return {"status": "error", "items": [], "reason": str(exc)}

    @tool
    def get_measurements(
        runtime: ToolRuntime[UserScope],
        measurement_type: str,
        days: int = 30,
        limit: int = 100,
    ) -> dict:
        """Typed body or vital measurements, e.g. weight, restingHeartRate, sleepDuration."""
        return loader.measurements(
            runtime.context.user_id,
            measurement_type,
            days=clamp(days, 1, MAX_DAYS),
            limit=clamp(limit, 1, MAX_LIMIT),
        )

    @tool
    def get_daily_snapshot(runtime: ToolRuntime[UserScope], days: int = 7) -> dict:
        """Daily ring summaries (sleep, readiness) around the session."""
        return loader.daily_snapshots(runtime.context.user_id, days=clamp(days, 1, 31))

    @tool
    def get_documents(
        runtime: ToolRuntime[UserScope],
        kind: str | None = None,
        limit: int = 5,
    ) -> dict:
        """Uploaded documents such as lab reports.

        A status of 'unconfigured' means document storage is not set up — it does NOT
        mean the user has no documents. Never tell the user they have none in that case.
        """
        return loader.documents(runtime.context.user_id, kind, limit=clamp(limit, 1, MAX_LIMIT))

    @tool
    def get_lab_results(
        runtime: ToolRuntime[UserScope],
        biomarker_id: str | None = None,
        days: int = 730,
        limit: int = 50,
    ) -> dict:
        """Lab values the user has confirmed from an uploaded report.

        Pass biomarker_id to follow one marker over time, or None for everything.

        These are measurements, not judgements. State them and compare them
        across dates; do NOT say whether a value is normal, high, low or
        concerning. Our reference ranges have not been reviewed by a clinician
        yet, so the app deliberately shows these numbers without any verdict and
        you must do the same. `operator` of '<' or '>' means the lab could not
        measure past that bound -- report it as written and never as the number
        alone.

        `genetic_context` may carry a wellness gene variant for some of these
        markers. It is CONTEXT and never a finding: it describes a tendency
        across groups of people, it says nothing about whether this person is
        deficient -- their result says that -- and it must never be offered as
        the reason their value is what it is. Mention it only if they ask
        about that marker, and never lead with it. Its `note` is null until a
        clinician has signed the explanation off, which is the case for every
        variant today: when it is null you may say which genotype they have
        and you may NOT say what it means.

        There is no way to ask for somebody's variants on their own, and that
        is deliberate. A genotype with no measured marker beside it is not
        something this product discusses.
        """
        results = loader.biomarker_results(
            runtime.context.user_id,
            biomarker_id,
            days=clamp(days, 1, 3650),
            limit=clamp(limit, 1, MAX_LIMIT),
        )
        context = loader.variant_context(runtime.context.user_id, results["items"])
        if context:
            results = {**results, "genetic_context": context}
        return results

    @tool
    def get_biological_age(runtime: ToolRuntime[UserScope]) -> dict:
        """The user's server-computed biological age, as stored.

        This is OUR number, computed from confirmed lab values on a published
        model (PhenoAge, Levine 2018). Quote it with its `as_of_date`, which is
        the date the blood was drawn and not today.

        `value` may be null, and null means UNKNOWN -- never zero and never
        "young". There are two reasons for it and `missing_inputs` says which:
        marker names mean the panel was incomplete, and `clinical_review` means
        we have the data but our reference ranges have not been reviewed by a
        clinician yet, so we are deliberately not giving a number. Say which
        applies. Do NOT estimate, infer or fill in a biological age yourself
        under any circumstances -- an invented one is the most convincing wrong
        number this product could produce.

        `drivers` carry each marker's contribution in years against an optimal
        value. Report them as written. Do not add a verdict of your own about
        whether a marker is high, low or concerning.
        """
        return loader.score_snapshot(runtime.context.user_id, "biological_age")

    @tool
    def get_epigenetic_clocks(
        runtime: ToolRuntime[UserScope], limit: int = 10
    ) -> dict:
        """Third-party epigenetic clock results the user already has.

        These are NOT ours. Horvath, Hannum, PhenoAge-DNAm, GrimAge and
        DunedinPACE results come from a provider the user paid, and we display
        and track them without ever computing one. Always name the `provider`
        when you mention a value, and never present one as our output or
        alongside our biological age as though the two were the same kind of
        thing.

        Different clocks disagree by years on the same sample. That is how the
        clocks are, not an error -- do not average them, reconcile them or pick
        the one that looks best.

        Mind the `unit`. DunedinPACE is a rate of ageing, not an age: 0.92 means
        ageing at 0.92 years per year, and calling it an age of 0.92 years is
        nonsense.
        """
        return loader.epigenetic_results(
            runtime.context.user_id, limit=clamp(limit, 1, MAX_LIMIT)
        )

    @tool
    def get_clinical_insights(
        runtime: ToolRuntime[UserScope], limit: int = 5
    ) -> dict:
        """Findings a clinician has signed off for this user.

        These are the only clinical claims in this product that a named human
        has agreed to. Each one carries `reviewer_name`, `reviewer_registration`
        and `reviewed_at`, and when you refer to a finding you may say a
        clinician reviewed it -- that is what those fields are for.

        **Check `delivery_route` first.** `clinician_signed` means a clinician
        read and signed exactly that text. `sla_expired` means NO clinician read
        it: it was released unreviewed because nobody reached it in time, and
        `reviewer_name` will be null. Never imply a review that did not happen,
        and never describe an `sla_expired` finding as reviewed, checked or
        confirmed by anyone.

        If `disputed_at` is set, the user has told us they disagree with it and
        `dispute_reason` says why. Do not quote it back at them as settled fact.
        Acknowledge the disagreement if it is relevant and move on.

        `body` is the finding as signed. Quote it or paraphrase it closely --
        do not extend it, sharpen it or add a verdict of your own. A clinician
        put their registration number against those words and not against
        yours, and `evidence` carries the values the finding rests on so you can
        cite them rather than inventing support.

        There is no tool for unreviewed drafts and there will not be one. A
        finding that is still waiting for a clinician does not exist as far as
        you are concerned.
        """
        return loader.clinical_insights(
            runtime.context.user_id, limit=clamp(limit, 1, MAX_LIMIT)
        )

    @tool
    def get_correlations(runtime: ToolRuntime[UserScope], days: int = 90) -> dict:
        """Patterns between the user's own daily series, already tested.

        The same computation the Correlations screen renders -- read it, do
        not redo it. Every pair here was declared in advance with a named
        physiological mechanism; pairs with no mechanism are never tested, so
        the absence of something the user asks about is not evidence against
        it and must not be reported as "no relationship".

        `reported` is what may be mentioned. `withheld` carries the same
        arithmetic and the reason it did not qualify, and is there so you can
        say we looked -- do NOT present a withheld pair as a finding. The
        reasons mean: `too_few_days` not enough matching days; `weak` real but
        too small to matter; `not_significant` could be chance; and
        `direction_mismatch` the two moved together but against the direction
        the mechanism predicts, which means we cannot explain it.

        `mechanism` is null until a clinician has signed that explanation off,
        and it is null today for every pair. When it is null you may say the
        two series moved together and you may NOT say why -- do not supply a
        reason of your own, however obvious it seems.

        Correlation is not cause. Say so if you report one, and never tell the
        user that changing one of the two will change the other.
        """
        return correlations.for_user(
            loader, runtime.context.user_id, days=clamp(days, 30, 90)
        )

    @tool
    def get_therapy_effects(runtime: ToolRuntime[UserScope], days: int = 365) -> dict:
        """What this user's own therapy sessions did to their readings.

        Already computed and already gated -- read it, do not redo it. Each
        session is its own control: the hour after against the hour before,
        averaged across sessions, so the number is a change and not a level.

        **Everything here is the hour after a session.** It says nothing about
        whether a therapy is making the user fitter, healthier or younger over
        months, and for several of these signals the long-term effect runs the
        OPPOSITE way to the short-term one. If they ask whether the sauna is
        working, say what it does in the hour afterwards and say plainly that
        we cannot yet answer the longer question.

        `reported` is what may be mentioned. `withheld` carries the reason it
        did not qualify and is never a finding: `too_few_sessions` means they
        have not done it enough times yet, `not_significant` means the
        sessions disagreed with each other, and `direction_mismatch` means the
        change ran against what the therapy is expected to do, which means
        something else was going on and we cannot attribute it.

        `sessions_confounded` counts sessions dropped because something else
        the user logged overlapped them. Worth mentioning when it is large:
        it is why the number of sessions used is lower than the number they
        remember doing.

        `mechanism` is null until a clinician signs that explanation off, and
        is null for everything today. When it is null you may state the
        measured change and you may NOT explain it.

        Never tell the user to start, stop, lengthen or shorten a therapy.
        """
        return therapy_effect.for_user(
            loader, runtime.context.user_id, days=clamp(days, 30, 365)
        )

    @tool
    def get_past_reports(runtime: ToolRuntime[UserScope], limit: int = 3) -> dict:
        """Previous activity reports, for continuity with advice already given."""
        return loader.past_activity_reports(runtime.context.user_id, limit=clamp(limit, 1, 10))

    return [
        get_past_sessions,
        get_logs,
        get_measurements,
        get_daily_snapshot,
        get_documents,
        get_lab_results,
        get_past_reports,
        get_correlations,
        get_therapy_effects,
        get_biological_age,
        get_epigenetic_clocks,
        get_clinical_insights,
    ]
