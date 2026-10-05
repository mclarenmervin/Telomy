import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/life_events/data/check_in_permission.dart';
import 'package:telomy/features/settings/services/notification_service.dart';

class FakeNotificationService implements NotificationService {
  FakeNotificationService({this.grant = true, this.throws = false});

  final bool grant;
  final bool throws;
  int asked = 0;

  @override
  Future<bool> requestPermission() async {
    asked++;
    if (throws) throw StateError('no plugin on this platform');
    return grant;
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  test('the first event start asks for permission', () async {
    final service = FakeNotificationService();
    final permission = CheckInPermission(service);

    await permission.ensure();

    expect(service.asked, 1);
  });

  test('later starts do not ask again', () async {
    /// The OS only shows its dialog once, but re-asking on every tap is a
    /// pointless await in the path between the tap and the event being created.
    final service = FakeNotificationService();
    final permission = CheckInPermission(service);

    await permission.ensure();
    await permission.ensure();
    await permission.ensure();

    expect(service.asked, 1);
  });

  test('a denied permission is remembered, not retried on every tap', () async {
    final service = FakeNotificationService(grant: false);
    final permission = CheckInPermission(service);

    await permission.ensure();
    await permission.ensure();

    expect(service.asked, 1);
    expect(permission.granted, isFalse);
  });

  test('a granted permission is recorded', () async {
    final permission = CheckInPermission(FakeNotificationService());

    await permission.ensure();

    expect(permission.granted, isTrue);
  });

  test('a platform that throws does not break starting an event', () async {
    final permission = CheckInPermission(FakeNotificationService(throws: true));

    await permission.ensure();

    expect(permission.granted, isFalse);
  });
}
