# F11 Centre Role Design

**Date:** 2026-10-13  
**Status:** Approved  
**Roadmap:** `docs/roadmap/F11-handoff-prompt.md` and F11 in
`docs/roadmap/2026-10-11-demo-parity-programme.md`

## Goal

Deliver the operational Centre Owner surface end to end: real centre tenancy,
rooms, services with indicative prices, concurrency-safe bookings,
consent-scoped members, deterministic business metrics, and a responsive
phone/tablet dashboard. Preserve the four-role model and the clinical authority
boundaries delivered by F9 and F10.

F11 is complete only when two independently operated centres cannot observe or
mutate one another's rows, and a patient's revoked or expired consent removes
that patient from every member list, risk list, and dashboard count on the next
request.

## Approved Role Model

The platform continues to have exactly four global roles:

| Database role | Product label | F11 authority |
|---|---|---|
| `admin` | Super Admin | Manage every centre's operational data; clinical reads remain audited and read-only |
| `centre` | Centre Owner | Manage the active centre's rooms, services, bookings, roster, and assignments |
| `doctor` | Doctor | Existing F10 clinical workspace and assigned patients only |
| `member` | Patient | Existing personal app, care-team view, and centre consent control |

F11 does not introduce receptionist, manager, therapist, or other global roles.
“Centre staff” means active Centre Owners and Doctors already represented by
`centre_memberships`. Patient self-booking is not part of F11.

A Centre Owner never gains clinical signing authority. Super Admin may perform
operational actions but may not alter clinician notes, signatures, reports, or
other clinical facts.

## Architecture Decision

Use normalized operational tables, database-enforced lifecycle rules, and a
membership-derived centre context.

Centre Owner endpoints do not accept `centre_id` in a path, query, or request
body. The mobile app sends an `X-Centre-Membership` header containing the
selected active owner-membership row. The gateway reads that row, verifies that
it belongs to the authenticated user, is active, has not ended, and belongs to
an active centre, then derives `centre_id` from it. No result is cached across
requests.

This supports an owner who operates multiple centres while satisfying the F11
rule that a centre route never trusts a raw tenant identifier. Existing F10
Centre Owner routes are migrated to the same context mechanism. Super Admin
uses separately protected admin routes with an explicit centre ID because an
admin has no owner membership and is intentionally cross-centre.

Rejected alternatives:

1. A server-side “selected centre” session adds mutable device-dependent state
   and makes concurrent phone/tablet use surprising.
2. Keeping `centre_id` in Centre Owner URLs, even with validation, preserves the
   cross-tenant footgun the F11 handoff explicitly rejects.

## Data Model

F11 adds one numbered migration after `027_doctor_workspace.sql`. Applied
migrations are never edited.

### Centre settings

Extend `centres` with:

- `timezone_name` — IANA timezone used for local operating hours and dashboard
  calendar boundaries.
- `currency_code` — ISO-4217 code used for new service prices, initially `INR`.

Both values are validated. Changing them affects future configuration and
bookings only; historical bookings retain snapshots.

### Rooms and availability

`centre_rooms` contains:

- immutable `id` and `centre_id`;
- centre-unique normalized name;
- `status` of `active` or `inactive`;
- audit fields and timestamps.

`centre_room_hours` contains one or more non-overlapping local-time availability
windows per room and weekday. Availability is configuration, not staff
rostering. Holidays and clinician schedules remain out of scope.

Rooms are retired by status rather than deleted. Existing bookings continue to
reference inactive rooms.

### Services

`centre_services` contains:

- immutable centre scope;
- name and optional non-clinical description;
- duration in minutes;
- indicative price in integer minor units;
- ISO currency code;
- active/inactive status;
- audit fields and timestamps.

`centre_room_services` links active rooms to the services they can host. Links
are ended, not deleted, so historical capacity calculations remain explainable.

No price represents a payment. Every API and UI field uses the word
“indicative.” Payments, invoices, refunds, and settlement remain out of scope.

### Bookings

`centre_bookings` contains:

- `centre_id`, `patient_id`, `service_id`, and `room_id`;
- scheduled start and end timestamps;
- status and monotonically increasing `version`;
- immutable snapshots of service name, duration, indicative price, and currency;
- creator and timestamps.

A patient must have an active patient membership in the same centre when a
booking is created. A room must be active and linked to the selected service.
The requested interval must fit an availability window and must not overlap an
active booking in that room. Booking creation acquires a transaction-scoped
advisory lock for the room and interval before checking and inserting, so two
concurrent requests cannot both pass the overlap check.

Direct authenticated insert/update/delete privileges are revoked. Creation and
transitions use security-definer procedures with pinned search paths and
current-state authorization checks. Historical bookings are never deleted.

`centre_booking_transitions` is append-only and records actor, from-state,
to-state, command, expected version, reason, and timestamp.

### Booking state machine

Allowed commands and transitions are:

```text
booked --check_in--> checked_in --complete--> completed
   |                       |
   |                       +--cancel--> cancelled
   +--mark_no_show--> no_show
   +--cancel---------> cancelled
```

Rules:

- every new booking starts as `booked`;
- callers send a command and expected version, never a target status;
- the procedure locks the row and rejects a stale version with a conflict;
- `mark_no_show` is allowed only when the centre-local scheduled start plus the
  15-minute grace period has passed;
- completed, no-show, and cancelled are terminal;
- direct status mutation is rejected;
- cancelling requires a non-empty reason after check-in;
- a terminal transition releases future room capacity but retains history.

The same transition implementation serves Centre Owner and Super Admin routes.

## Consent and Member Visibility

The existing `clinical_access_consents` fact remains the authority. F11 adds an
expiry timestamp and updates `centre_can_read_clinical` so active means:

- purpose is `clinical_care`;
- not revoked;
- not expired;
- patient membership is active;
- Centre Owner membership and centre are active.

Existing active consent rows receive a documented one-year expiry during the
migration. New grants default to one year and may be renewed by the patient.
Revocation and expiry are evaluated from PostgreSQL on every request, never from
JWT claims, mobile state, or gateway cache.

The Centre Owner member list is built from current qualifying consents, not
from the patient roster. A patient who is a centre member but never consented
appears nowhere in the member list, risk list, member count, activity count, or
“not seen” count.

The list returns the patient's display name, operational booking history, care
team assignment summary, and non-diagnostic follow-up status. It does not expose
email, phone number, address, bulk export, medication text, raw biomarkers, or
clinical-draft content.

Each patient represented in a member or risk response receives an append-only
access-audit record. The read fails closed if audit recording fails. Revocation
between two requests removes the row on the second request.

## Scoped Loaders and Backend Boundaries

Add a Centre Owner-only loader under `app/gateway`, separate from the agent's
`ContextLoader`. It accepts an already resolved access scope and places
`centre_id` on every query. It never becomes an agent tool and never broadens
the member loader.

The loader owns reads for:

- rooms and room hours;
- services and compatible rooms;
- bookings;
- consent-scoped members;
- the minimum health evidence required to derive non-diagnostic risk status.

Mutations go through database procedures. Python maps database conflicts to
stable HTTP responses and does not duplicate authorization or state-machine
logic.

## Deterministic Metrics

One pure Python analytics module defines dashboard metrics. Both the dashboard
endpoint and future reporting callers use it. The module documents calendar,
status, denominator, and grace-period rules and is tested against hand-worked
fixtures.

All month and day boundaries use the centre's timezone.

### Indicative revenue

Sum the immutable indicative price snapshots of bookings completed within the
selected calendar month. Show the current month and immediately preceding
calendar month. Cancelled, no-show, booked, and checked-in rows contribute zero.

The response and UI label this “indicative booking value,” not payment revenue.

### Sessions

Count bookings completed within the selected period.

### No-show rate

For bookings whose start plus the 15-minute grace period is in the past:

```text
no_show / (completed + no_show)
```

Cancelled rows, future bookings, currently booked rows inside the grace window,
and checked-in rows are excluded. A zero denominator returns no rate rather
than a fabricated zero percent.

### Utilisation per service

For each service:

```text
completed scheduled minutes / configured bookable room minutes
```

The denominator is the sum of room-hour windows for rooms linked to that
service during the selected period. Overlapping room windows are forbidden.
The numerator uses the booking's duration snapshot. Cancelled and no-show rows
consume no utilised minutes. Results are clamped only after detecting and
logging inconsistent data; math never silently hides an over-capacity defect.

The UI explains that this is configured room-capacity utilisation and does not
include staff rostering or machine availability.

### Member metrics

- **Members:** current unexpired consents.
- **Active in 30 days:** consented members with at least one completed booking
  in the trailing 30 × 24-hour window.
- **Not seen in 30 days:** consented members without a completed booking in that
  window, including never-seen members.
- **Today's bookings:** non-cancelled bookings whose local scheduled date is
  today, ordered by start time.

### Members at risk

Risk is a deterministic commercial follow-up flag, never a diagnosis. It is
derived only for currently consented members from existing severity and marker
trend functions. The Centre Owner receives:

- `follow_up_recommended`;
- the broad evidence class and date;
- the safe action “Suggest a doctor consultation or retest.”

The response omits marker values, diagnostic labels, treatment instructions,
and unsigned clinical text. With no qualifying evidence the member is not put
on the risk list. A withdrawn, revoked, expired, or unconsented member is absent.

## Gateway API

Centre Owner routes require authentication plus `X-Centre-Membership`:

- `GET /api/v1/centre/mine`
- `GET /api/v1/centre/dashboard`
- `GET /api/v1/centre/members`
- `GET /api/v1/centre/doctors`
- `POST /api/v1/centre/invitations`
- assignment routes without a centre path segment
- CRUD-style command routes for rooms, room hours, services, and compatibility
- `GET/POST /api/v1/centre/bookings`
- `POST /api/v1/centre/bookings/{booking_id}/transitions`

Centre-scoped IDs are looked up through the resolved scope. A UUID from another
centre returns not found, preventing the response from becoming an existence
oracle.

Super Admin receives equivalent operations below
`/api/v1/admin/centres/{centre_id}/operations`. These routes require the current
database role `admin`, reuse the same operational service functions, and do not
grant clinical mutation rights.

List endpoints are bounded and paginated. No bulk member export exists.

## Flutter Experience

The Centre Owner role keeps the shared F9 shell and changes its five primary
destinations to:

1. Dashboard
2. Bookings
3. Members
4. Services
5. Profile

Doctor roster and patient assignment management remain reachable from Members
and Profile/Team. Rooms and availability are managed inside Services. This
preserves the F10 provisioning capability while matching the F11 operational
information architecture.

### Dashboard

The phone layout uses a scrollable metric-card grid followed by today's
bookings, utilisation, members needing follow-up, and not-seen members. Every
financial card says “indicative.” Empty, loading, stale, and denied states use
the existing shared vocabulary.

At widths of 760 px or more, the existing `NavigationRail` remains the primary
navigation. Dashboard sections use the extra width rather than stretching
single-column cards.

### Bookings

The screen provides date/status filters, booking creation, and only the
commands legal for the current returned status/version. The server remains the
authority: a stale action refreshes the booking and explains that another user
changed it.

### Members

Only consent-scoped members render. A member row may show last visit,
next booking, assigned doctor, and safe follow-up status. Invitation and doctor
assignment workflows remain available but roster membership is visually
separate from consented member visibility.

### Services and rooms

Centre Owners create and retire services, set duration and indicative price,
configure compatible rooms, and maintain weekly room hours. Historical price
snapshots are never rewritten.

### Honest deferred states

- Service outcomes state that personalised outcome evidence arrives with F12.
- Live Floor state that machine/session telemetry arrives with F13.
- Neither placeholder fabricates data or presents an enabled dead-end action.

## Error Handling

- Missing/invalid membership context: 403 without tenant details.
- Cross-centre object ID: 404.
- Invalid transition: 409 with current status and version.
- Stale expected version: 409 and refresh hint.
- Booking overlap or outside availability: 409 with a non-sensitive reason.
- Expired/revoked consent: member disappears; a direct detail request returns
  404 after recording the denied access attempt where possible.
- Audit failure: 503 and no protected payload.

## Security Invariants

1. Every Centre Owner query is scoped by a centre derived from current
   membership.
2. Centre A cannot select, infer, update, transition, count, or aggregate a
   Centre B row.
3. RLS protects authenticated direct database reads; gateway service-role code
   independently scopes every query.
4. Consent is evaluated on every read and is never cached.
5. Booking state changes and history are database constrained.
6. Prices are immutable booking snapshots and always labelled indicative.
7. Centre Owner risk output is non-diagnostic and contains no treatment advice.
8. Super Admin operational authority does not confer clinical write authority.
9. The agent receives no new clinical or Centre Owner data tool.
10. No member bulk export or unconstrained contact-list endpoint exists.

## Test Strategy

Development follows RED → GREEN → REFACTOR.

### PostgreSQL

- two centres and two owners, testing each as the authenticated role;
- zero cross-centre room, service, booking, member, or aggregate rows;
- direct DML refusal;
- room-hour non-overlap and booking collision under concurrent attempts;
- every valid and invalid booking transition;
- stale version conflict;
- no-show grace boundary immediately before and at 15 minutes;
- append-only transition history;
- consent grant, expiry, renewal, and immediate revocation;
- never-consented patient absent from all reads and counts;
- Super Admin operational authority and clinical mutation refusal.

### Python

- membership-context resolution with active, suspended, ended, foreign, and
  multi-centre memberships;
- every loader query includes derived centre scope;
- fail-closed audited member reads;
- hand-worked current/previous month revenue;
- sessions, no-show denominator, grace boundary, utilisation denominator,
  active/not-seen membership, and timezone boundaries;
- deterministic safe risk projection;
- API 401/403/404/409 mappings and pagination.

### Flutter

- repository sends membership context and never a raw Centre Owner centre ID;
- centre switching invalidates centre-specific providers;
- dashboard cards and honest labels;
- booking creation and transition conflicts;
- consented member versus roster presentation;
- service/room editing and validation;
- all five Centre Owner routes at phone width;
- `NavigationRail` and usable dashboard at ≥760 px;
- no Centre Owner access from other roles by deep link.

### Full verification

- all PostgreSQL tests;
- full backend pytest suite;
- full Flutter test suite and analyzer;
- staging migration dry-run, then migration `028` through the deployment runner;
- staging deployment health for all Railway services;
- release APK built with staging Supabase configuration;
- install and verify login, centre selection, dashboard, booking lifecycle,
  consent revocation, phone layout, and tablet-width layout on connected Android
  hardware/emulator;
- record exact commits, migration checksum, test counts, staging revision, and
  device evidence in `docs/roadmap/F11-completion-report.md`.

## Rollout and Recovery

The migration is additive. Existing F10 tables and clinical history are not
deleted. New Centre Owner screens are deployed only after the schema is
available. If the application release must be rolled back, the additive tables
and booking history remain intact; old F10 clients continue to authenticate.

The existing centre-ID Centre Owner endpoints are removed only in the same
release that updates the mobile repository calls. Super Admin and Doctor paths
are unaffected.

## Explicitly Deferred

- personalised per-service outcomes and research view — F12;
- live therapy floor, machines, and telemetry — F13;
- payments, invoicing, refunds, and settlement;
- staff rostering and clinician schedules;
- inventory;
- patient self-booking;
- receptionist/manager roles;
- holidays beyond configured weekly room availability;
- bulk export or marketing contact lists.

## Definition of Done

F11 is done only when all of the following are evidenced:

- Centre Owners can manage their rooms, services, bookings, doctors, patients,
  and assignments on phone and tablet layouts.
- The dashboard reports the specified deterministic metrics with clear
  indicative-price and capacity definitions.
- Two-centre tests prove no row or aggregate crosses the tenant boundary.
- Consent revocation and expiry remove a member immediately from lists, risk,
  and counts.
- Invalid and concurrent booking transitions fail in PostgreSQL.
- Super Admin can perform operational administration without clinical writes.
- Full SQL, backend, Flutter, analyzer, staging, and Android verification is
  green and recorded.
