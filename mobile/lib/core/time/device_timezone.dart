import 'package:flutter_timezone/flutter_timezone.dart';

/// The user's IANA timezone, recorded on their profile so the backend can
/// compute a day the way their phone does.
///
/// Without it the server scores on UTC day boundaries while the app scores on
/// local ones — a 5.5-hour disagreement for IST about where a day starts, which
/// during the shadow comparison reads as a model bug and is not one.

/// Returns the profile with the device's timezone recorded.
///
/// Returns the *same* map when nothing would change, so callers can skip a
/// pointless write and the sync it would trigger.
Map<String, String> withDeviceTimezone(
  Map<String, String> profile,
  String? reported,
) {
  final zone = (reported ?? '').trim();
  // An unreadable zone leaves the last known one in place. Blanking it would
  // make the server fall back to UTC without anyone noticing.
  if (zone.isEmpty || profile['timezone'] == zone) return profile;
  return {...profile, 'timezone': zone};
}

/// Reads the device timezone, or null when the platform cannot say.
Future<String?> readDeviceTimezone() async {
  try {
    return (await FlutterTimezone.getLocalTimezone()).identifier;
  } catch (_) {
    return null;
  }
}
