# Telomy — Demo-parity programme (F9 → F19)

**Date:** 2026-10-11
**Source of the scope:** the prototype at `github.com/anshumanastronaut/telomy`
(read at commit `acf01f0`, v0.4), which was shown to the business and to
investors. Everything in that prototype is to exist in the production app.
**Status of this document:** the plan. The eleven phase prompts beside it
([F9](F9-handoff-prompt.md) … [F19](F19-handoff-prompt.md)) are how it gets
built, and [the inventory](2026-10-11-demo-inventory.md) records what the
prototype actually contains — every screen, module, route and token — so that no
phase has to clone it again.
**Verified against the code on 2026-10-11**, not against anybody's claims —
including the prototype's own README.

---

## 1. Three corrections before anything is planned

**1. F8 is open and moving as this is written.** **F0–F7 are shipped** (sync
ownership, units and biomarkers, scores in Python with golden fixtures, lab
ingest, biological age v2, the clinician spine, supplements, the concierge). F8
— correlations v2, genetics, environment, therapies — began on 2026-10-11:
`b3d6adf` landed the inference primitives (a sample-size floor,
Benjamini–Hochberg, and the Bartlett/Quenouille adjustment for lag-1
autocorrelation, in ordinary Python rather than scipy) and `b919202` landed the
plausibility gate, where a pair is tested only if somebody declared the
hypothesis and the explanation appears only if somebody signed it. That is
`app/analytics/correlations.py`, and it is the file F12 and F16 build on.

Its other three items are not built: there is no `exposome` anywhere in the
tree, genetics exists only as a free-text journal kind, and therapies are
generic journal entries. **F8 finishes first; F9 does not start before it** —
and anyone reading this document should check `git log` rather than trust this
paragraph, because the phase was moving while it was being written.

**2. There were no F9 or F10 prompts to find.** The approved plan
(`~/.claude/plans/i-got-new-request-dynamic-emerson.md`) stops at F8 with
"additive, any order", and the twelve-capability table it is built on is
complete at F8. Everything after F8 lived only as waves 3–8 of
[the combined roadmap](2026-10-06-combined-roadmap.md), which was written before
anyone had read the prototype. F9–F19 are new, and this document is where they
come from.

**3. The two repositories share no code.** The prototype is Expo / React Native
over FastAPI and SQLite, 154 REST routes, 26 tables, one profile (`pid = 1`),
and an OTP endpoint that accepts `000000`. Production is Flutter over Supabase
with Python workers, RLS, real auth and real wearable data. Nothing merges.
**What the prototype is, precisely, is an executable specification** — 9,854
lines of backend logic with the formulas, the citations and the refusals already
worked out, plus 73 screens that show what each role is supposed to see. Read it
that way and it is worth more than a PRD. Read it as a codebase to copy and it
will teach the production app bad habits.

### The honesty note that has to travel with this scope

The prototype's `backend/app/seed.py` **plants the causal effects the engine
then discovers** — alcohol → next-night HRV −9 ms, sauna → deep sleep +0.25 h,
and, deliberately, HBOT and red light → no next-day effect at all. That is good
practice for verifying an engine. It also means the prototype demonstrates that
the mathematics is correct on data whose answer is already known, and
demonstrates nothing about whether these effects are detectable in real wearable
variance. We have already met this problem from the other side: the check-in
thresholds were tuned against synthetic data with a standard deviation near
1 bpm, and real all-day wearable data runs 10–15 bpm
([combined roadmap §3.1](2026-10-06-combined-roadmap.md)). Every therapy verdict,
every correlation and every twin projection ported from the prototype inherits
that risk, and each phase below says what it must display when the honest answer
is "no reliable signal".

---

## 2. The role model

The prototype has three roles in one binary — `user`, `doctor`, `centre` —
switched by `AsyncStorage` with no server-side authorisation whatsoever
(`mobile/src/lib/role.tsx`). We need four, and we need them enforced in
Postgres, which is a different piece of work from what the prototype did.

| Role | Who they are | What the app is for them | Prototype has it |
|---|---|---|---|
| **Member** | the person whose body it is | Vault, scores, therapy, plan, Sinc, family sharing | yes, as `user` |
| **Doctor** | a registered clinician in the Bonphul network | work queue, patient panel, sign-offs, consults, monthly reports | yes, with no authorisation |
| **Centre** | a wellness / longevity centre owner or operator | dashboard, members, services, bookings, live therapy floor, machines | yes, single-tenant |
| **Platform admin** | us | every other role's accounts, clinician licences, centre onboarding, catalogue signatures, queue health, consent and erasure audit, device registry, flags | **no — this is new design** |

Two things follow and both are decisions, not details.

**The admin role is ours to design, not to port.** Nothing in the prototype
corresponds to it. What it must do is already visible in the production
codebase's own failure modes: `stranded_total` exists because there is no
console to claim a draft; `biomarkers.v1.yaml` and `supplements.v1.yaml` are
blocked on a clinician's signature with no interface to collect one; DPDP gives
a user erasure rights that someone has to be able to honour and prove. F9
defines it, and it is first in the sequence because it is the only role that can
unblock the others.

**`clinic_members.role` is not the platform role.** 013 already constrains it to
`('patient', 'clinician', 'admin')` — that is a membership role *inside one
clinic*, and `clinician_may_sign()` depends on it. The platform role is a
different axis: one person may be a member of Telomy and a clinician at two
clinics and an operator of one centre. F9 adds `app_role` as its own thing and
never overloads the clinic role to mean both. Getting this wrong is a
cross-tenant data leak, which is the one class of bug CLAUDE.md says application
code is solely responsible for preventing.

### What each role gets out of it, in one line each

Worth stating because the sequence is ordered by it, and because these are the
sentences the business already used.

- **The member** gets a reason to keep the ring on: a number that moves, a
  therapy verdict that says "this one does nothing for you", and a clinician's
  name against anything that sounds like advice.
- **The doctor** gets a patient prepared for the consultation — a brief, a
  summary, a priority list — and gets to decide instead of to type. The
  prototype's work queue refuses to let a plan be signed without a note; keep
  that.
- **The centre** gets to see utilisation, no-shows, members at risk and the
  floor in real time, and gets per-service outcome evidence it can sell against.
  This is the only role with a direct revenue argument.
- **The platform** gets the thing none of the three can give itself: proof that
  what we told the first three is true, and a way to stop it when it is not.

---

## 3. The design system is already shared

`mobile/src/lib/theme.ts` in the prototype and
[app_colors.dart](../../mobile/lib/app/theme/app_colors.dart) in production both
carry teal `#1F5C4E`, and both cite "UI Design System v1.0". The prototype's
palette is a strict superset of ours: it adds copper `#A9643A` as the human
counterweight to teal-as-science, a full status ramp (optimal / in range / out
of range / awaiting clinician / signed / rejected), soft backgrounds for every
status, and a complete dark mode. Typography is Inter for UI with Fraunces as
the display serif.

**So this is a token extension, not a redesign.** F9 ports the tokens and the
component vocabulary; every later phase spends them. The vocabulary worth
copying by name, because the prototype's 73 screens are built from fourteen
pieces and nothing else:

`Screen` (pull-to-refresh, max width) · `Card` (optional `tone`: teal, copper) ·
`Row` · `Section` (title + one optional action) · `T` (one typographic scale,
`v="h1" | "h3" | "body" | "small" | "label" | "num"`) · `Chip` · `StatusChip` ·
**`Prov`** (source · when · confidence, under any number) · **`ConfBar`** ·
`Stat` · `Segmented` · `ListRow` · `Empty` (title + body + actions, never a
blank list) · `Loading` (says what is loading) · `ErrorState` (with retry) ·
`Toast`.

Two of those are the roadmap's own Wave 1 wearing different clothes. `Prov` is
**F01 the provenance chip**; `ConfBar` is **F02 the confidence gradient**; the
"How this is calculated" link on every score card is **F06 open methods**. The
prototype shipped all three as components first and used them everywhere after,
which is the right order and the opposite of how a feature usually arrives.
F9 ports them, and from F9 onward a number rendered without `Prov` is a review
failure.

---

## 4. The nine clusters, and where each one lands

The nine clusters are the gap analysis against the prototype. The phase column
is the commitment.

| # | Cluster | Phase |
|---|---|---|
| 1 | Three-sided platform — doctor and centre role surfaces | **F9** spine · **F10** doctor · **F11** centre |
| 2 | Therapy stack — catalogue, safety, sessions, verdicts, plans | **F12**, with in-session physiology in **F13** |
| 3 | Machine telemetry — device keys, channels, alarms, live floor | **F13** |
| 4 | Vault breadth — report types, imaging, tests catalogue, completeness | **F14** |
| 5 | Risk prediction and the digital twin | **F15** |
| 6 | Engine depth — N-of-1 studies, cross-modality rules, receipts | **F16** (after F8's correlations v2) |
| 7 | Sinc extras — voice, voice stress, routines, custom activities | **F17** |
| 8 | Telomy Rx — formulas, interactions, e-prescription, adherence | **F18** |
| 9 | Care and distribution long tail — brief, sharing, consent, nudges | **F19** |

Plus the platform admin role, which is cluster 1's fourth side and lands in F9
with the spine.

### Sequence

```
F8   correlations v2 · genetics · environment · therapies     ← open; lands first
F9   role spine · platform admin · design tokens · Prov/ConfBar
F10  doctor role: work queue · patients · summaries · monthly reports
F11  centre role: tenancy · services · bookings · members · dashboard
F12  therapy spine: catalogue · safety screen · sessions · verdicts · plans
F13  machines: telemetry · channels · alarms · live floor · in-session physiology
F14  vault breadth: report types · imaging · tests catalogue · completeness
F15  risk equations · what-ifs · digital twin · mirror
F16  engine depth: N-of-1 studies · cross-modality rules · receipts
F17  voice · voice stress · routines · custom activities
F18  Telomy Rx: formulas · interactions · e-prescription · adherence
F19  brief (PDF + FHIR) · family sharing · consent · nudges · the rest
```

**Why this order.** F9 is first because three roles cannot be built before
authorisation exists, and because `Prov` has to precede every screen that would
otherwise render a number bare. F10 before F11 because the doctor's signature is
what makes a therapy plan or an Rx legal, and F12 depends on it. F13 after F12
because telemetry with nothing to attach it to is a stream into a void. F14 and
F15 are independent of the therapy chain and can run in parallel with it if
there are two people. F16 needs F8's engine work underneath it. F17, F18, F19
are additive by construction and can be reordered against commercial need —
F19's specialist brief is the cheapest credibility in the whole programme and
can jump the queue if a clinic partner asks for it.

---

## 5. The phases

Each phase has a prompt file beside this one. What follows is the scope and the
definition of done, which is what the prompt is accountable to.

### F9 — Role spine, platform admin, design tokens

The foundation. `app_role` on the profile with Postgres enforcement, not an
`AsyncStorage` string; a navigation shell per role; the platform admin surface;
the design tokens and the fourteen components, `Prov` and `ConfBar` among them.

**Done when:** a member cannot reach a doctor route by deep link or by any SQL
they can issue; a clinician sees only patients who share with them; a centre
operator sees only their centre; an admin action is in an audit table that the
admin cannot edit; every score on every existing screen renders through `Prov`;
`flutter test` and `pytest` both green; verified on `Pixel_8`.

### F10 — The doctor role

The work queue in five segments (reports, Sinc drafts, consults, therapy plans,
Rx plans), the patient panel with deterministic priority, patient detail, notes,
the AI report summary and patient summary, monthly report generate → sign. The
clinician spine from F5 and F6 is the engine; this is the first interface it has
ever had.

**Done when:** `stranded_total` can be driven to zero by a human using the app;
nothing can be signed without a note; a signature is bound to the exact body
that was signed (`gate_delivery`, already built, is what enforces it); a report
summary is composed deterministically and quotes no number a tool did not
return.

**This changes a decision.** The approved plan says the clinician console is a
separate repo with no agent access. Putting the doctor role in the member app is
what was demonstrated and what is now asked for. The prompt says how to keep the
property that mattered — the agent still cannot read `clinical_drafts`, because
there is still no loader method for it — but the decision itself belongs to
whoever owns the regulatory posture, and F10 should not start until they have
said yes.

### F11 — The centre role

Real multi-tenancy: a centre, its staff, its services with prices, bookings with
status transitions, members who have consented to share, the dashboard with
revenue, utilisation, no-shows and lapsing members, and per-service outcomes.

**Done when:** two centres exist in the database and neither can see one row of
the other's, proved by a test that runs as each of them; a member's appearance on
a centre dashboard is traceable to a consent row and disappears when it is
revoked.

### F12 — The therapy spine

The catalogue (~25 modalities with what each does, who it is not for, and what it
costs), the deterministic safety screen from the Vault, the session lifecycle,
before-and-after effect with the verdict vocabulary — *Helped*, *Promising*,
*Possible negative*, *No reliable signal*, *Too early*, *In-session only* — and
the plan builder that ends at the doctor's signature from F10.

**Done when:** a therapy the Vault contraindicates cannot be started or booked by
any path; "no reliable signal" and "too early" render as first-class answers with
their own screens, not as empty states; a verdict of *Helped* requires both FDR
significance and split-half replication, and the test proves a verdict
downgrades when replication is removed.

### F13 — Machines and what happens inside them

Device registry, per-device keys with rotation, the channel schema per machine
type with hard limits, alarms, the telemetry endpoint, the patch sample endpoint,
the live floor that refreshes every fifteen seconds, and in-session physiology:
HR surge, HRV suppression and rebound, recovery constant *k*, rewarming
half-time, SpO₂ kinetics, safety tiers.

**Done when:** telemetry with a bad key is refused before any field is read
(CLAUDE.md's first security rule, and the prototype's device key check is the
shape to copy); a value outside a hard limit raises an alarm on the floor;
delivered dose is computed against the prescription; **every simulated number is
labelled simulated on screen**, because this is the phase where the prototype's
physiology priors are most tempting to present as measurement. HSAI is specified
here and deliberately not shipped — see §7.

### F14 — Vault breadth

More report types and coded markers with sex-specific zones, the imaging record
(metadata and the report, not DICOM), the tests and scans catalogue with
preparation, interval and indicative Indian pricing, and Vault completeness with
a concrete list of what raises it.

**Done when:** the censored (`<0.01`), qualitative (`Not detected`) and
same-marker-twice cases from the approved plan's edge-case list all have tests;
a historical backfill of five years of reports fires no alerts and creates no
drafts; completeness is computed from the same marker catalogue the scores use.

### F15 — Risk prediction and the twin

PREVENT 2024, the Pooled Cohort Equations with the South-Asian caveat shown, the
ADA score, FIB-4 and KFRE, each with what-ifs; then the twin, its 21 state
variables, the 24-hour twin and the mirror that scores its own fidelity.

**Done when:** each equation reproduces its published worked example to the
paper's own precision, as a test; a model refuses rather than defaults when sex,
age or a required marker is missing; the twin is labelled a projection
everywhere it appears and its mirror score is on the same screen as its output.

### F16 — Engine depth

After F8's correlations v2: N-of-1 ABAB studies the member can start, the
cross-modality rule set, lab × wearable windows, and the receipts surface —
adjusted versus unadjusted effect, CI, p, n, covariates, and the citation.

**Done when:** a study can return "no difference" and that reads as a result;
every insight has a receipt; no rule fires from a genetic variant alone (F8's
rule, and F16 is where it will be tempting to break it).

### F17 — Voice, routines, activities

Voice to text to a row in `events` — which is P1, so this is additive by
construction and is Build Order step 8. Voice-stress acoustics as an explicitly
evidence-C wellness signal. Routines parsed from free text into a weekly
schedule with adherence. Custom activity types, created by voice or by hand,
with their own baselines.

**Done when:** a voice command produces the same `events` row shape a button
press does and nothing downstream can tell which fired; voice stress is never
presented as a clinical measure; an activity with fewer than its minimum
sessions says so instead of showing a baseline.

### F18 — Telomy Rx

Formulas, supplements, prescription medicines and clinic IVs; interaction
checking; the plan that goes to a doctor and comes back signed, item-edited and
dose-edited; the e-prescription; adherence. F6 built the supplement half of this
and the signature machinery; F18 is its full surface.

**Done when:** a major interaction blocks an item and says why; the exclusion
list is visible to the member with reasons ("not offered, and why" is a screen in
the prototype and should be one here); a dispensing path exists only against a
signed prescription; nothing is orderable that a clinician did not sign.

### F19 — Care, distribution, and the long tail

The specialist brief as a print-ready PDF and a FHIR-shaped bundle; family
sharing with scoped, time-limited, revocable shares and an access log;
per-purpose DPDP consent with history; the emergency card; pinned metrics;
notifications and nudges; the action plan; protocols; meal analysis and menu
swaps; goals; breathe; memories; appointments; subscriptions.

**Done when:** the brief replaces the `Clipboard.setData` export the audit
flagged; a revoked share stops resolving immediately and the revocation is in the
access log; consent is per purpose and erasure purges Storage as well as
Postgres.

---

## 6. Decisions this programme forces

Each of these is cheap now and expensive in three phases' time.

| # | Decision | Recommendation |
|---|---|---|
| 1 | Doctor role in the member app, or the separate console the plan specified? | In-app, as demonstrated — but the agent still gets no path to `clinical_drafts`. Needs the regulatory owner's yes before F10. |
| 2 | `app_role` as a profile column, a JWT claim, or both? | Column as the fact, claim as the cache, every policy reading the column. F9 writes the test that proves a stale claim grants nothing. |
| 3 | Is a centre a tenant of `clinics`, or a new `centres` table? | New table. A clinic signs; a centre sells. Overloading `clinics` puts `clinician_may_sign` in the booking path. |
| 4 | Machine telemetry over HTTPS, MQTT, or both? | HTTPS first (the prototype's bridge is 60 lines and can wait). Which machines can speak at all is open question 3 in CLAUDE.md and blocks F13. |
| 5 | How are simulated physiology values presented? | As simulated, always, with the prototype's own honesty rule copied verbatim into the guardrails. A simulated number that reads as a measurement is the single worst outcome available to this programme. |
| 6 | Does HSAI ship? | Not in F13. It is an unvalidated composite index with no test–retest data, and it is the easiest thing here to mistake for a diagnosis. Specify it, build the domains it needs, ship it when someone will stand behind it. |
| 7 | Payments: are centre bookings and Rx orders transacted in-app? | Out of scope for F9–F19. Every price renders as indicative until a payment decision exists. The prototype's `₹1499` hardcoded listings are already a release blocker in the audit. |
| 8 | Who signs the clinical content? | Still unanswered since F6, and now it blocks more: biomarker ranges, supplement rules, therapy contraindications, the Rx exclusion list. F9's admin surface is where a signature can finally be collected; it does not produce the signatory. |

---

## 7. Risks

| Risk | Cheapest de-risk |
|---|---|
| Effects real in seeded data are undetectable in real variance; the therapy tab reads as broken | Instrument every verdict's margin from the first session. "No reliable signal" has to be designed as a good screen, not an error state |
| Eleven phases of new surface on a roadmap that has not yet closed F8 | F8 first, and F14/F15 are the two that can run in parallel if there is a second pair of hands |
| Simulated physiology shown as measured | Decision 5, enforced in the guardrails rather than in review |
| Three new roles, one RLS mistake, cross-tenant health data | Each role phase ships with a test that runs *as* the other roles and asserts zero rows |
| The doctor queue is empty because nothing is signed, or full because nobody signs | `stranded_total` is already the metric; put it on the admin dashboard in F9, before the queue has users |
| The admin role becomes a God account | Admin actions are append-only and admin-visible; no admin path reads a member's health rows without a consent row |
| Scope read as "the prototype, ported" | This document is the scope. The prototype is the reference. Where they disagree, this document and CLAUDE.md win |

---

## 8. Deliberately not in this programme

- **DICOM viewing.** F14 takes the imaging *record*; the viewer needs radiology
  partners and is the largest single lift in the product. Unchanged from the
  approved plan.
- **MQTT, and the device simulator as production tooling.** F13 ships HTTPS.
- **HSAI, PINN-trained physiology, the therapy response-phenotype study.** All
  three need real sessions in volume. Specify, do not ship.
- **Payments.** Decision 7.
- **The B2B SDK and white-label layer.** Not what was demonstrated, and not ours.
- **Always-on voice.** F17 ships push-to-talk. A wake word needs native build
  work and a speaker-verification answer.
- **Community.** Production has it and the prototype does not. It stays, and this
  programme does not touch it.

---

## 9. What F19 delivers, and what it does not

Stated plainly because the sequence invites the opposite reading. **At the end of
F19 the product is feature- and UI-complete: every screen the prototype
demonstrated, for four roles instead of three, with authorisation actually
enforced in Postgres and real data underneath.** It is not launchable, and
nothing in F9–F19 makes it so. Six gates sit outside this programme and five of
them are not engineering.

| Gate | State on 2026-10-11 | Owner |
|---|---|---|
| **Payments** | Out of scope by decision 7. `marketplace_catalog.dart` still ships `price: 1499` hardcoded — a release blocker in the audit. Bookings, Rx orders and subscriptions all stop at "indicative" | commercial + a payments phase |
| **Clinical signatures** | Five reviewed-content files exist (`biomarkers`, `supplements`, `correlations`, `therapies`, `variants`), each signed per entry and bound to a content hash. **Zero signatures in any of them.** Unsigned content stays invisible or ungraded by design, so the app can be complete and still show an empty biological age | a registered clinician; open since F6 |
| **Clinician supply** | F10 builds the interface, not the panel. With nobody signing, every draft strands — `stranded_total` is the metric | Bonphul network / operations |
| **Machine integrability** | Open question 3 in CLAUDE.md, unanswered since the platform HLD. F13 ships the contract and ingest; without machines that can emit, the live floor is a simulator | centre partners |
| **Hosting and release** | No CI in this repo. Supabase on the Free plan. The iOS project exists but no phase, prompt or doc covers signing, TestFlight or store submission, and every device check is Android `Pixel_8` — iOS has never been verified | platform |
| **Hardening** | No phase is security review, load test, DPDP audit or retention enforcement. Telemetry retention is open question 6 | platform |

Also still out, so nobody counts them as delivered: DICOM, HSAI (decision 6),
always-on voice, the household dashboard, aggregate research and Telomy Labs,
and the detector — which means that at F19 events are still logged by hand and
the "effortless" story in the decks remains unbuilt, blocked on the same
unanswered wearable question as before.

**Recommendation:** an F20 that is nothing but release readiness — CI, a paid
tier, the iOS path, a hardening pass and the retention policy — scoped once the
signature and payments decisions have answers. It is deliberately not written
yet, because three of its six inputs are not ours to decide.

---

## 10. How a phase runs

The convention this repo already uses, unchanged: one prompt file per phase,
read in a fresh session, TDD throughout, both suites green before each commit,
small commits whose messages say why, push to `staging`, and verify on the
device before calling a phase done — every phase so far has found a bug there
that all the tests passed through.

A phase prompt is accountable to its "done when" above. If a prompt and this
document disagree, this document is stale and the prompt should say so.
