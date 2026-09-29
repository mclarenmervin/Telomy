# Data and ring integration

## Data flow

Manual entries, platform health imports, and wearable observations are
normalized into `JournalEntry` and `HealthMeasurement` records. Riverpod keeps
the current account state consistent, while serialized repository writes avoid
overwriting simultaneous manual and wearable updates.

Supabase stores each module in a dedicated user-owned table. Health
measurements retain source, device, quality, observation time, and optional end
time. Wearable devices and daily reports have separate tables. Row-level
security limits access to the authenticated owner. Encrypted platform storage
is used as an offline fallback.

## Platform health

Apple Health and Android Health Connect are available under Settings → Health
data. Access is requested only after explicit user action. Supported readings
from the previous 30 days are normalized and deduplicated during sync.

## Mini Zone / Bonlala ring

The Android flow is:

1. Scan nearby BLE advertisements with `flutter_blue_plus`.
2. Let the user choose a ring.
3. Connect through the bundled Bonlala SDK.
4. Subscribe to continuous notifications and request device metadata and daily
   history.
5. Validate values, update the wearable screen, and persist readings locally
   and in Supabase.

The native channel is `telomy/wearable_sdk`. Live packets provide heart rate
and steps; the SDK also broadcasts measured SpO₂. Daily frames contain fixed
slots for heart rate, steps/sleep, SpO₂, HRV, stress, temperature, and activity.
Only values with understood units and valid ranges are promoted to the health
timeline. The original daily snapshot is retained for history views.

Connections stop when the app is backgrounded, the user signs out, or the ring
is disconnected. Forgetting a ring removes its app binding without performing
a hardware factory reset. iOS ring sync requires a vendor-supported iOS SDK.

## Integration constraints

Close Mini Zone before connecting because a BLE peripheral normally accepts a
single active client. Data availability depends on what the ring has recorded.
Missing readings are shown as unavailable rather than replaced with demo data.
Vendor SDK redistribution and supported hardware models should be confirmed
before public store distribution.
