import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/life_events/models/life_event.dart';

void main() {
  group('LifeEventType catalog', () {
    test('offers the types the backend can reason about', () {
      final keys = LifeEventType.all.map((t) => t.key).toList();

      expect(keys, contains('alcohol'));
      expect(keys, contains('sauna'));
      expect(keys, contains('cold_plunge'));
      expect(keys, contains('smoking'));
    });

    test('every type has a label and an icon so the grid never renders blank', () {
      for (final type in LifeEventType.all) {
        expect(type.label, isNotEmpty, reason: '${type.key} has no label');
        expect(type.key, isNot(contains(' ')), reason: '${type.key} is not a db key');
      }
    });

    test('a known key resolves back to its type', () {
      expect(LifeEventType.byKey('sauna')?.label, 'Sauna');
    });

    test('an unknown key resolves to null rather than throwing', () {
      expect(LifeEventType.byKey('teleportation'), isNull);
    });
  });

  group('LifeEvent', () {
    test('reads an open event from a row', () {
      final event = LifeEvent.fromRow({
        'id': 'e1',
        'event_type': 'sauna',
        'status': 'started',
        'started_at': '2026-10-04T14:00:00+00:00',
        'ended_at': null,
      });

      expect(event, isNotNull);
      expect(event!.id, 'e1');
      expect(event.isOpen, isTrue);
      expect(event.label, 'Sauna');
    });

    test('an ended event is not open', () {
      final event = LifeEvent.fromRow({
        'id': 'e1',
        'event_type': 'sauna',
        'status': 'ended',
        'started_at': '2026-10-04T14:00:00+00:00',
        'ended_at': '2026-10-04T15:00:00+00:00',
      });

      expect(event!.isOpen, isFalse);
    });

    test('falls back to the raw key when the type is unknown to the app', () {
      final event = LifeEvent.fromRow({
        'id': 'e1',
        'event_type': 'hyperbaric',
        'status': 'started',
        'started_at': '2026-10-04T14:00:00+00:00',
      });

      expect(event!.label, 'hyperbaric');
    });

    test('a row with no id is rejected rather than half-built', () {
      expect(LifeEvent.fromRow({'event_type': 'sauna', 'status': 'started'}), isNull);
    });

    test('elapsed counts from the start time', () {
      final event = LifeEvent.fromRow({
        'id': 'e1',
        'event_type': 'sauna',
        'status': 'started',
        'started_at':
            DateTime.now().toUtc().subtract(const Duration(minutes: 23)).toIso8601String(),
      });

      expect(event!.elapsed().inMinutes, 23);
    });
  });
}
