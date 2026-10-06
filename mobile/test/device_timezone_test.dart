import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/core/time/device_timezone.dart';

void main() {
  test('a reported timezone is recorded on the profile', () {
    final updated = withDeviceTimezone(const {'height': '175'}, 'Asia/Kolkata');

    expect(updated['timezone'], 'Asia/Kolkata');
    expect(updated['height'], '175', reason: 'other fields are untouched');
  });

  test('a changed timezone overwrites the old one', () {
    /// Travel, or a phone that was set up in the wrong region.
    final updated = withDeviceTimezone(
      const {'timezone': 'Europe/London'},
      'Asia/Kolkata',
    );

    expect(updated['timezone'], 'Asia/Kolkata');
  });

  test('an unchanged timezone returns the identical map so no sync is triggered', () {
    const profile = {'timezone': 'Asia/Kolkata'};

    expect(withDeviceTimezone(profile, 'Asia/Kolkata'), same(profile));
  });

  test('an empty or unknown reading leaves the profile alone', () {
    /// Better to keep the last known zone than to blank it and have the server
    /// silently fall back to UTC.
    const profile = {'timezone': 'Asia/Kolkata'};

    expect(withDeviceTimezone(profile, ''), same(profile));
    expect(withDeviceTimezone(profile, null), same(profile));
  });

  test('a profile with no timezone and no reading stays without one', () {
    expect(withDeviceTimezone(const {}, null), isEmpty);
  });
}
