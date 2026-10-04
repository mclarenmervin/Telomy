import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/life_events/models/event_check_in.dart';

Map<String, dynamic> row({
  String kind = 'check_in:hr_elevated',
  String summary = 'Your heart rate is 18 bpm above your usual.',
  List<String> flags = const [],
  String createdAt = '2026-10-04T15:02:19+00:00',
}) => {
  'id': 'p1',
  'event_id': 'e1',
  'kind': kind,
  'summary': summary,
  'guardrail_flags': flags,
  'created_at': createdAt,
};

void main() {
  test('a check_in row is parsed with its reason', () {
    final checkIn = EventCheckIn.fromRow(row());

    expect(checkIn, isNotNull);
    expect(checkIn!.reason, 'hr_elevated');
    expect(checkIn.summary, 'Your heart rate is 18 bpm above your usual.');
    expect(checkIn.eventId, 'e1');
  });

  test('the ack is parsed, because it is what confirms tracking started', () {
    final checkIn = EventCheckIn.fromRow(row(kind: 'ack', summary: 'Got it.'));

    expect(checkIn!.kind, EventPredictionKind.ack);
    expect(checkIn.reason, isNull);
  });

  test('the closing analysis is parsed', () {
    final checkIn = EventCheckIn.fromRow(row(kind: 'analysis', summary: 'During…'));

    expect(checkIn!.kind, EventPredictionKind.analysis);
  });

  test('an activity_summary row is not an event prediction', () {
    expect(EventCheckIn.fromRow(row(kind: 'activity_summary')), isNull);
  });

  test('a row with an empty summary is rejected rather than shown blank', () {
    expect(EventCheckIn.fromRow(row(summary: '   ')), isNull);
  });

  test('an escalation flag is surfaced as a property, not left in a raw list', () {
    final checkIn = EventCheckIn.fromRow(row(flags: const ['escalation']));

    expect(checkIn!.needsEscalation, isTrue);
  });

  test('no flags means no escalation', () {
    expect(EventCheckIn.fromRow(row())!.needsEscalation, isFalse);
  });

  test('check-ins are the only kind that interrupts the user', () {
    expect(EventCheckIn.fromRow(row())!.isCheckIn, isTrue);
    expect(EventCheckIn.fromRow(row(kind: 'ack'))!.isCheckIn, isFalse);
    expect(EventCheckIn.fromRow(row(kind: 'analysis'))!.isCheckIn, isFalse);
  });

  test('a malformed kind is rejected', () {
    expect(EventCheckIn.fromRow(row(kind: 'check_in:')), isNull);
    expect(EventCheckIn.fromRow(row(kind: 'nonsense')), isNull);
  });

  test('a missing created_at does not throw; it sorts oldest', () {
    final checkIn = EventCheckIn.fromRow({...row(), 'created_at': null});

    expect(checkIn, isNotNull);
    expect(checkIn!.createdAt.year, lessThanOrEqualTo(DateTime.now().year));
  });
}
