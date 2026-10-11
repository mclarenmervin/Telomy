Read first, in this order:

docs/roadmap/2026-10-11-demo-parity-programme.md — §2, §5 (F11), and decision 3:
a centre is a new table, not a tenant of `clinics`.
healthagent/CLAUDE.md — the Non-Negotiable Rules. "Application code is solely
responsible for tenant isolation" is the sentence this phase lives under.
healthagent/db/013_clinical_review.sql — how a membership table and its policies
were done once already, including the recursion scar.

What F11 is: the centre's side of the product. Tenancy (a centre, its staff, its
rooms), a service catalogue with indicative prices, bookings with status
transitions, the member list limited to people who have consented to share, and
the dashboard: revenue this month against last, sessions, members, active in 30
days, no-shows, today's bookings, utilisation per service, members at risk, and
who has not been seen in 30 days. Per-service outcomes are specified here and
cannot be computed until F12 produces verdicts; render the honest placeholder,
which says what it needs and when it will have it.

Already built (F0–F10), reuse it:

db/013_clinical_review.sql — the pattern for a scoped membership table, and
  `clinician_may_sign()` as the example of a check evaluated at the moment of
  the act rather than at claim time
app/gateway/auth.py — `current_user_id()`. A centre route resolves the centre
  from the signed-in operator's membership, never from a path parameter. A
  `centre_id` in a URL is this phase's cross-tenant bug
app/common/context_loader.py — one method per table, scoped. The centre's reads
  are a new scoped loader; do not widen the member one
app/analytics/severity.py + marker_trends.py — "members at risk" is derived from
  these, deterministically, and only for members who consented
F9's role spine — `app_role`, the shell, the component vocabulary. If F11 is
  adding a navigation fork, F9 is incomplete and should be fixed instead

Seven things that will bite you:

1. **Two centres, and neither sees a row of the other's.** Write that test
   first, as both operators, before the first table has a policy. This is the
   whole phase; everything else is a dashboard.

2. **A member on a centre dashboard is a consent, not a customer record.** The
   prototype says it on screen — "risk comes from members' shared Vault data,
   with their consent" — and then shows names and risk anyway because it has one
   profile and no consent enforcement. Production inverts that: the dashboard
   reads a consent row, the row has a purpose and an expiry, and revocation
   takes effect on the next read with no cache in between. Test the revocation,
   not the grant.

3. **Revenue is money, so it is reconciled, not computed in a view.** Decision 7
   keeps payments out of this programme, which means every figure on this
   dashboard is derived from bookings at indicative prices and must say so. A
   centre owner who makes a decision on a number we invented will not forgive it.

4. **Booking status is a state machine and it will be edited by two people at
   once.** Booked, checked in, completed, no-show, cancelled. Transitions are
   constrained in the database, not in the client, and the client sends the
   transition rather than the target state. Two staff checking in the same member
   from two phones is the ordinary case, not the edge case.

5. **No-shows and utilisation are the numbers the business will quote.** Define
   them once, in Python, with a docstring saying what is included — utilisation
   over what denominator, no-show after what grace period — and expose them
   through one implementation with two callers. If the dashboard and a later
   report disagree by one booking, trust in both collapses, which is the dual-math
   defect F2 spent a phase closing in a different place.

6. **The member list is not a mailing list.** No bulk export, no contact
   details beyond what the consent purpose covers. The access log from F19 is
   what makes this auditable; until then, log the reads anyway.

7. **"Members at risk" is clinical-adjacent language on a commercial screen.**
   The claims firewall applies: a centre operator is not a clinician and the
   screen must not read as a diagnosis or produce a treatment instruction. The
   prototype's own wording — suggest a doctor consult or a retest — is the right
   altitude. Anything stronger needs F10's signature behind it.

Verification:

- Two centres, each operator, zero cross-rows. Then a member revokes, and the
  row disappears on the next read.
- Every booking transition that should be impossible, attempted directly against
  the API.
- Utilisation and no-shows asserted against a fixture with a hand-worked answer,
  including the grace-period boundary.
- A member who never consented appears nowhere, including in counts.
- On the device: the dashboard at phone width, and the rail at ≥ 760 px, because
  a centre operator is the one role likely to use a tablet.

Commands: as in F9-handoff-prompt.md.

Working style: TDD throughout, isolation tests before features, small commits
that say why, both suites green before each commit, push to staging, verify on
`Pixel_8`.

Deliberately left for later:
- Per-service outcome evidence (needs F12's verdicts) and the research view
  (needs volume). Placeholders that say what they are waiting for.
- The live therapy floor and machines are F13. A dashboard tile may link to
  them; it may not pretend to have them.
- Payments, invoicing, staff rostering, inventory. None of it was demonstrated
  and none of it is in this programme.
