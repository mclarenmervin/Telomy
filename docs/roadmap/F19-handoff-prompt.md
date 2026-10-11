Read first, in this order:

docs/roadmap/2026-10-11-demo-parity-programme.md — §5 (F19). This phase is
fifteen small things; the order inside it is commercial, not technical, and the
specialist brief is first because it is the cheapest credibility in the
programme.
~/.claude/plans/i-got-new-request-dynamic-emerson.md — the deletion and consent
paragraphs. "Deletion must purge Storage" is a DPDP obligation and a one-line
omission, and this phase is where consent stops being a toggle.
healthagent/db/009_storage_purges.sql, 010_storage_purge_listing.sql,
015_erasure_over_append_only.sql — erasure already fought append-only once and
won. Read how before adding a shareable artefact.

What F19 is: the long tail that makes the product usable by other people. The
specialist brief as a print-ready PDF and a FHIR-shaped bundle; family sharing
with scoped, time-limited, revocable shares and an access log; per-purpose DPDP
consent with history; the emergency card; pinned metrics; notifications and
nudges; the action plan; protocols; meal analysis and menu swaps; goals;
breathe; memories; appointments; subscriptions. Each is small. Two of them —
the brief and consent — are the ones with consequences.

Already built (F0–F18), reuse it:

db/015_erasure_over_append_only.sql — the precedent: a user with a signed
  recommendation must still be erasable. A share, a brief and an access log are
  three more append-only things that must not make a person unerasable
db/009 + 010_storage_purge*.sql — Storage purging, already built, already tested
app/common/context_loader.py — every read scoped. A share is a second reader of
  someone else's rows and needs its own scoped loader, not a parameter on the
  member's
F9's audit table — the access log is the same shape and should not be a second
  mechanism
app/scheduler/ — digests, reports, threshold sweeps. Nudges are a scheduler job,
  not a client-side timer
app/analytics/ — the action plan is assembled from what already exists; it is
  not a new computation

Nine things that will bite you:

1. **The brief replaces a genuine privacy failure.** The current export is
   `Clipboard.setData`, and Samsung's clipboard history retains it — the audit
   called it a P0. Deleting that path is part of this phase, not a follow-up.

2. **FHIR is a contract with strangers.** A bundle that is nearly FHIR is worse
   than a PDF, because a clinic's system will ingest it and be wrong. Validate
   against a real validator, map only the resources we can populate honestly, and
   omit rather than approximate. Observation, DiagnosticReport, Patient,
   MedicationStatement is a defensible first set.

3. **A brief is a point-in-time artefact and will be read months later.** It
   carries its generation date, the ranges version, the model versions and a
   statement of what was and was not included. A brief that silently reflects
   "now" when reopened is a clinical hazard.

4. **A revoked share stops resolving on the next read, with no cache in
   between** — and the revocation is itself in the access log. Test the
   revocation, the expiry, and the case where a share is revoked while the other
   person has the screen open.

5. **Scoped means scoped.** A share of "sleep" does not leak a lab value through
   an insight that mentions one, or through a chart's axis label, or through a
   nudge. The test enumerates what the scope permits and asserts everything else
   is absent from the payload — not from the screen.

6. **Per-purpose consent is a schema change and retrofitting it is the trap.**
   The combined roadmap says to start it early and it is now late. Purposes:
   care, research, marketing, third-party sharing, centre visibility (F11
   depends on that one and shipped before this). Each independently grantable and
   revocable, with history, and the research purpose is what any future aggregate
   work rests on.

7. **Nudges are the easiest way to become annoying and the easiest way to look
   broken.** Deterministic rules decide whether to fire, the LLM only ever words
   it (CLAUDE.md), there is a per-day cap, and silence is a valid output. A nudge
   that fires on a stale baseline is worse than none, which is F13's staleness
   problem reaching the notification tray.

8. **The emergency card is read by someone who is not the member, under
   pressure, possibly on a locked phone.** Allergies, conditions, medications,
   blood group, a contact. It is the one screen in the product where a
   disclaimer, a loading spinner or a clever layout is a defect. Decide whether
   it works offline; the answer should be yes.

9. **Memories are long-term agent state and are namespaced `("memories",
   user_id)`** — the namespace *is* the isolation boundary. A member-editable
   memory screen means a member can now write into the agent's context, which is
   a prompt-injection surface in their own account. Keep it data, never
   instructions, and keep safety-critical facts out of it: allergies and
   conditions are fetched deterministically and a memory must never be the only
   place one lives.

Verification:

- The brief: generated, validated against a FHIR validator, reopened after a
  range version change and asserted unchanged.
- `Clipboard.setData` export gone, by grep and by test.
- Share: granted, scoped, read, expired, revoked mid-session, logged at each
  step.
- Scope leakage: the enumerated payload test in bite 5.
- Consent: five purposes, each granted and revoked independently, with history,
  and a research-purpose revocation that removes the member from any aggregate.
- Erasure: a member with a signed insight, a share, an access log, a brief in
  Storage and a memory — all of it gone, proved including Storage.
- Nudges: the per-day cap, the stale-baseline refusal, and a day with none.
- Emergency card with the network off.

Commands: as in F9-handoff-prompt.md.

Working style: TDD throughout. For erasure specifically, test the behaviour and
not the schema — F6 shipped a bug precisely because a test asserted
`confdeltype = 'c'` instead of deleting an account. Small commits that say why.
Both suites green. Push to staging. Verify on `Pixel_8`.

Deliberately left for later:
- Payments and subscription billing (decision 7). A subscription is a record of
  what a member is entitled to, not a transaction.
- Aggregate research, Telomy Labs, preprint reading — unblocked by the research
  consent this phase adds, and then their own programme.
- The household dashboard (U09/F09 in the older numbering). It needs this
  phase's per-member consent and is the strongest India-specific
  differentiator; it is also the one place the shared-account problem has to be
  solved rather than detected.
