import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/life_events/models/event_check_in.dart';
import 'package:telomy/features/life_events/models/life_event.dart';
import 'package:telomy/features/life_events/providers/life_event_state.dart';

LifeEvent openEvent({String id = 'e1'}) => LifeEvent(
  id: id,
  eventType: 'sauna',
  status: 'started',
  startedAt: DateTime.utc(2026, 10, 4, 14),
);

EventCheckIn checkIn({
  String reason = 'hr_elevated',
  String eventId = 'e1',
  int minute = 2,
  EventPredictionKind kind = EventPredictionKind.checkIn,
}) => EventCheckIn(
  eventId: eventId,
  kind: kind,
  summary: 'reason=$reason',
  reason: kind == EventPredictionKind.checkIn ? reason : null,
  createdAt: DateTime.utc(2026, 10, 4, 14, minute),
);

void main() {
  test('with no event the card is idle', () {
    expect(const LifeEventState().isRunning, isFalse);
  });

  test('an open event makes it running', () {
    expect(LifeEventState(event: openEvent()).isRunning, isTrue);
  });

  test('an ended event is not running', () {
    final ended = LifeEvent(
      id: 'e1',
      eventType: 'sauna',
      status: 'ended',
      startedAt: DateTime.utc(2026, 10, 4, 14),
      endedAt: DateTime.utc(2026, 10, 4, 15),
    );

    expect(LifeEventState(event: ended).isRunning, isFalse);
  });

  group('receiving predictions', () {
    test('a check-in for the open event is kept', () {
      final state = LifeEventState(event: openEvent()).receive(checkIn());

      expect(state.checkIns.single.reason, 'hr_elevated');
    });

    test('a prediction for a different event is ignored', () {
      final state =
          LifeEventState(event: openEvent()).receive(checkIn(eventId: 'other'));

      expect(state.checkIns, isEmpty);
    });

    test('the same reason arriving twice is kept once', () {
      /// Realtime delivers both the INSERT and a later UPDATE of the same row;
      /// showing the user two identical cards would read as being nagged.
      final state = LifeEventState(event: openEvent())
          .receive(checkIn())
          .receive(checkIn());

      expect(state.checkIns, hasLength(1));
    });

    test('a different reason is added alongside', () {
      final state = LifeEventState(event: openEvent())
          .receive(checkIn(reason: 'hr_elevated', minute: 2))
          .receive(checkIn(reason: 'hrv_suppressed', minute: 3));

      expect(state.checkIns.map((c) => c.reason),
          containsAll(['hr_elevated', 'hrv_suppressed']));
    });

    test('check-ins are ordered newest first', () {
      final state = LifeEventState(event: openEvent())
          .receive(checkIn(reason: 'hr_elevated', minute: 2))
          .receive(checkIn(reason: 'hrv_suppressed', minute: 3));

      expect(state.checkIns.first.reason, 'hrv_suppressed');
    });

    test('the ack is recorded separately so the card can confirm tracking', () {
      final state = LifeEventState(event: openEvent())
          .receive(checkIn(kind: EventPredictionKind.ack, minute: 0));

      expect(state.acknowledged, isTrue);
      expect(state.checkIns, isEmpty);
    });

    test('the closing analysis is held as the summary, not as a check-in', () {
      final state = LifeEventState(event: openEvent())
          .receive(checkIn(kind: EventPredictionKind.analysis, minute: 60));

      expect(state.analysis, isNotNull);
      expect(state.checkIns, isEmpty);
    });

    test('a prediction arriving with no open event is ignored', () {
      expect(const LifeEventState().receive(checkIn()).checkIns, isEmpty);
    });
  });

  test('starting a new event clears the previous conversation', () {
    final state = LifeEventState(event: openEvent())
        .receive(checkIn())
        .receive(checkIn(kind: EventPredictionKind.ack, minute: 0))
        .startedWith(openEvent(id: 'e2'));

    expect(state.checkIns, isEmpty);
    expect(state.acknowledged, isFalse);
    expect(state.analysis, isNull);
    expect(state.event!.id, 'e2');
  });
}
