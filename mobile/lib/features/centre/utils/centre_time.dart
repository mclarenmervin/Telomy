import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

bool _initialized = false;

tz.Location centreLocation(String timezoneName) {
  if (!_initialized) {
    tz_data.initializeTimeZones();
    _initialized = true;
  }
  try {
    return tz.getLocation(timezoneName);
  } catch (_) {
    return tz.UTC;
  }
}

DateTime centreLocalTime(DateTime instant, String timezoneName) =>
    tz.TZDateTime.from(instant.toUtc(), centreLocation(timezoneName));

DateTime centreUtcTime(
  DateTime day,
  int hour,
  int minute,
  String timezoneName,
) => tz.TZDateTime(
  centreLocation(timezoneName),
  day.year,
  day.month,
  day.day,
  hour,
  minute,
).toUtc();
