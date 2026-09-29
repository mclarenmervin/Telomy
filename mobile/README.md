# Telomy

Telomy is a Flutter health and fitness app that combines daily wellness tracking, longitudinal insights, and Android smart-ring data in one personal timeline.

## Features

- Supabase authentication and user-scoped cloud synchronization
- Dashboard, trends, correlations, readiness, and longitudinal insights
- Nutrition, workouts, hydration, sleep, body composition, goals, and check-ins
- Medications, lab records, therapies, consultations, and health timeline
- Android Mini Zone/Bonlala smart-ring connection over Bluetooth LE
- Ring-powered activity sessions for running, swimming, cycling, walking, strength training, and yoga
- Live heart rate, battery, firmware, steps, SpO₂, HRV, stress, and sleep history when supplied by the ring
- Local encrypted fallback for offline access
- Light, dark, phone, and tablet layouts

## Technology

- Flutter and Dart
- Riverpod and GoRouter
- Supabase Auth and PostgreSQL with row-level security
- `flutter_blue_plus` with the bundled Bonlala Android SDK
- `fl_chart` for health trends

## Setup

Install Flutter 3.38 or newer, then fetch dependencies:

```sh
flutter pub get
```

Copy the environment template and add your Supabase project URL and publishable key:

```sh
cp .env.example .env.supabase
```

Run the app:

```sh
flutter run --dart-define-from-file=.env.supabase
```

Build an Android release:

```sh
flutter build apk --release --dart-define-from-file=.env.supabase
```

Never commit database passwords, service-role keys, or `.env.supabase`.

## Database

Supabase migrations are in [`supabase/migrations`](supabase/migrations). The schema uses dedicated, user-owned tables for health measurements, wearable devices and reports, activity sessions, preferences, meals, workouts, hydration, medications, labs, consultations, community activity, and other modules. Row-level security restricts every personal record to its authenticated owner.

Apply migrations with the Supabase CLI:

```sh
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
```

## Smart ring

The native Bonlala SDK files required for Android are included under `android/app/libs`. To sync a ring:

1. Close Mini Zone so it releases the Bluetooth connection.
2. Open **Wearables → Add ring**.
3. Grant Nearby Devices permission and select the ring.
4. Keep the ring nearby and tap **Sync ring**.

Ring data availability depends on the device firmware and the samples recorded by the ring. The vendor integration is currently Android-only.

## Quality checks

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
```

## Project structure

```text
lib/app/                 Navigation and application theme
lib/core/                Shared API, auth, storage, and widgets
lib/features/            Feature-first screens, models, and services
android/app/libs/        Bonlala wearable SDK dependencies
supabase/migrations/     PostgreSQL schema, functions, and RLS policies
test/                    Unit, widget, responsive, and persistence tests
docs/                    Architecture and integration notes
```

Telomy is a wellness tracking application and does not provide medical diagnosis or emergency monitoring.
