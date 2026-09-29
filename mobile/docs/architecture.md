# Architecture

Telomy is a feature-first Flutter application. The Flutter iOS project is
`ios/Runner.xcworkspace`; Android sources are under `android/`.

## Application layers

- `lib/app`: themes, navigation, and the adaptive application shell.
- `lib/core`: shared API, authentication, configuration, storage, and widgets.
- `lib/features`: screens, providers, models, repositories, and domain services.
- `supabase/migrations`: PostgreSQL tables, transactional functions, indexes,
  and row-level security policies.

Riverpod providers expose application state to the UI. Repositories own local
and remote persistence. Health and journal models provide a shared normalized
format used by dashboards, trends, reports, correlations, and insights.

## Persistence

Authenticated data is written to dedicated Supabase tables through
`save_normalized_wellness`, which replaces a user's logical snapshot in one
database transaction. `load_normalized_wellness` reconstructs the app model.
Every personal table uses `auth.uid()` row-level security. Encrypted local
storage provides offline fallback. The original `wellness_documents` table is
retained only to migrate accounts created before the normalized schema.

## Wearables

Android ring discovery uses `flutter_blue_plus`. Device communication uses the
bundled Bonlala SDK through the `telomy/wearable_sdk` method channel in
`MainActivity.kt`. The bridge validates live packets, imports daily history,
and sends normalized data to Flutter. Apple Health and Health Connect use the
`health` package behind explicit consent controls.

The Bonlala vendor SDK is Android-only. An iOS ring integration requires an iOS
SDK or a documented Bluetooth protocol from the hardware vendor.

## Security

The client receives only a Supabase publishable key. Database passwords and
service-role keys must remain outside the application. Tokens and offline data
use platform secure storage. Personal health payloads are not logged.
