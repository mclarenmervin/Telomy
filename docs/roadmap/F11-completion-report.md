# F11 Centre Role Completion Report

**Status:** Complete on staging  
**Verified:** 2026-10-15 IST  
**Staging commit:** `c5ffecd161414ad315089f26d33eaec056919e76`  
**Migration:** `028_centre_operations.sql`  
**Migration SHA-256:** `5ab98f3cd9c4639f09b54742c2df7757fb8def23b82e6c21dddfc6b694eefe21`

## Delivered surface

F11 now provides a membership-selected Centre Owner workspace with Dashboard,
Bookings, Members, Services, and Profile destinations. Centre scope is derived
from an authenticated active owner-membership header; Centre Owner URLs and
payloads never choose a raw centre ID. A multi-centre owner can switch centres,
and every centre-specific provider refreshes on the switch.

The operational surface includes:

- deterministic dashboard metrics with explicit indicative-price wording;
- rooms, weekly availability, services, room compatibility, and retirement;
- named patient/service/compatible-room booking creation and the complete
  versioned booking state machine;
- a contact-free operational patient roster that remains available when
  clinical-data consent is absent or revoked;
- a separate, consent-scoped Members view with audited clinical reads;
- doctor invitation and patient assignment workflows;
- Super Admin operational parity without clinical mutation authority.

The final acceptance pass found and corrected two UUID usability defects.
Booking cards now show contact-free patient and room labels, and booking
creation now uses scoped named selectors instead of requiring raw patient,
service, and room identifiers.

## Automated verification

| Layer | Result |
|---|---|
| Backend | `1722 passed`, 49 existing deprecation warnings, `TZ=UTC` |
| Flutter | `546 passed` |
| Flutter analyzer | No issues found |
| PostgreSQL booking concurrency | Both overlap and stale-version races passed against a temporary local PostgreSQL instance |
| SQL migration suite | Passed, including tenancy, lifecycle, consent, transition, and policy assertions |
| Release build | Built successfully with the staging Supabase configuration |

The two concurrency cases initially could not start `initdb` inside the
filesystem sandbox. They were rerun with the required local PostgreSQL access
and both passed; the subsequent full backend run passed all 1722 tests in one
run.

## Staging evidence

- `origin/staging` was updated to the verified F11 commits.
- Gateway `/health` returned HTTP 200.
- The deployed contact-free patient-roster route returned HTTP 401 without a
  JWT, proving the new route was live and authentication-protected.
- Migration 028 was applied by the pre-deploy path and its checksum matched the
  source above.
- An isolated two-centre acceptance owner resolved two active memberships.
- Centre A and Centre B returned distinct rooms and services with zero
  cross-centre rows or aggregates.
- A cross-centre object lookup returned not found rather than revealing object
  existence.
- The live scenario created and transitioned a booking, verified dashboard
  metrics, granted consent, then revoked it and observed immediate removal from
  Members and clinical counts.
- After revocation, the contact-free operational patient roster still contained
  the patient, preserving booking and assignment operations without exposing
  clinical detail.

No acceptance credential, JWT, patient identifier, device serial, wearable
identifier, contact field, or clinical value is stored in this report.

## Android phone verification

**Device:** moto g(60), Android 12 / API 31, 1080×2460 at 400 dpi  
**Device serial:** redacted  
**App:** v1.26.0 (`versionCode 27`)  
**APK SHA-256:** `610eedd99d7f09915213029915f1db567e27ae82df42240f85307823d920de3a`  
**APK source commit:** `c5ffecd161414ad315089f26d33eaec056919e76`

The release APK was installed with replacement over the isolated Centre Owner
acceptance session. The following passed on the physical phone:

- Centre Owner login and the exact five-role navigation destinations;
- Centre A dashboard, services/rooms, bookings, Members, assignments, and team;
- Centre A booking cards showed patient/room labels and no UUIDs;
- booking editor showed named patient, service, and compatible-room selectors;
- booking creation at a configured room time;
- `booked → checked_in → completed`, with terminal controls removed;
- revoked consent removed the person from clinical Members immediately;
- the same person remained in the operational patient roster and the doctor
  assignment dialog remained available;
- Centre B showed only its own room/service, no doctors, no bookings, and zero
  dashboard counts;
- centre switching refreshed all scoped screens;
- cold launch resolved the deterministic default active membership;
- app process remained alive with no Android crash or Flutter exception.

The only app-process error-level log line was Flutter clamping an out-of-order
frame timestamp; it was not an exception and did not affect navigation or data.
Sanitized local evidence was captured as UI hierarchy/screenshot references for
the named booking editor, consent-revoked roster, assignment dialog, both-centre
service lists, booking transitions, and dashboard states. These temporary files
were deliberately not committed.

## Tablet verification

The Centre Owner shell and all five destinations were exercised at ≥760 px on
an Android tablet/emulator. NavigationRail, dashboard card layout, services,
bookings, Members, and Profile rendered without overflow. Widget coverage also
pumps the centre shell and dashboard at phone and tablet widths.

## Patient and ring regression

The mandatory regression passed on the same physical phone using the preceding
F11 binary (`cfd79be`, APK SHA-256 prefix `8bdce910…5f9d`):

- Mini Zone connected without a connectivity error;
- battery and firmware rendered;
- live heart-rate and step readings streamed beyond battery/firmware;
- a smoking event started, accumulated approximately three minutes, stopped,
  and returned to idle;
- the server stored exactly one ended lifecycle row with a positive 203-second
  duration and produced two downstream prediction rows;
- no BLE, authentication, gateway, Flutter, or Android crash occurred;
- patient-facing correlation wording retained the claims firewall.

The final `c5ffecd` delta is restricted to Centre Owner roster/booking APIs and
UI, and the complete 1722-backend/546-Flutter regression suites passed after
that delta. No patient BLE, event, telemetry, or claims code changed.

The patient timeline currently lists journal entries and wearable measurements,
not backend lifecycle events. Therefore the smoking event does not appear in
“Life events & daily logs.” This is existing product behavior and is recorded as
a separate product follow-up, not an F11 Centre Owner defect.

## Definition-of-done mapping

| F11 requirement | Evidence |
|---|---|
| Membership-derived tenancy | Resolver/API tests, protected deployed route, two-centre live scenario |
| Rooms/services/availability | SQL/backend/Flutter suites, Centre A/B phone screens |
| Booking creation and lifecycle | Database transition/concurrency tests, API scenario, physical-phone create/check-in/complete |
| Consent-scoped clinical members | Audited loader tests and immediate live/phone disappearance after revocation |
| Operational patients and assignments | Contact-free roster tests plus physical-phone roster and assignment dialog after revocation |
| Deterministic dashboard | Analytics tests, two-centre live metrics, phone and tablet screens |
| Tenant isolation | SQL/backend cross-centre tests plus Centre A/B staging and phone evidence |
| Super Admin without clinical writes | Role/authorization tests and immutable-clinical-content regressions |
| Responsive Centre Owner UI | 546 Flutter tests, analyzer, phone and ≥760 px tablet/emulator evidence |
| Existing patient/ring path preserved | Physical Mini Zone smoking-event regression and full post-fix suites |

F11 has no remaining implementation or staging blocker.
