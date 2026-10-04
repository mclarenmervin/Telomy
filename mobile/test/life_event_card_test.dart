import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/life_events/models/event_check_in.dart';
import 'package:telomy/features/life_events/models/life_event.dart';
import 'package:telomy/features/life_events/providers/life_event_state.dart';
import 'package:telomy/features/life_events/widgets/life_event_card.dart';

LifeEvent running() => LifeEvent(
  id: 'e1',
  eventType: 'sauna',
  status: 'started',
  startedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 23)),
);

EventCheckIn aCheckIn({bool escalate = false}) => EventCheckIn(
  eventId: 'e1',
  kind: EventPredictionKind.checkIn,
  reason: 'hr_elevated',
  summary: 'Your heart rate is 18 bpm above your usual 62.',
  needsEscalation: escalate,
  createdAt: DateTime.now().toUtc(),
);

Widget host(LifeEventState state) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: LifeEventCardBody(
        state: state,
        onStart: (_) {},
        onStop: () {},
      ),
    ),
  ),
);

void main() {
  testWidgets('idle offers the event types by name', (tester) async {
    await tester.pumpWidget(host(const LifeEventState()));

    expect(find.text('Alcohol'), findsOneWidget);
    expect(find.text('Sauna'), findsOneWidget);
    expect(find.text('Smoking'), findsOneWidget);
  });

  testWidgets('tapping a type starts that event', (tester) async {
    String? started;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: LifeEventCardBody(
            state: const LifeEventState(),
            onStart: (type) => started = type.key,
            onStop: () {},
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Sauna'));
    await tester.pump();

    expect(started, 'sauna');
  });

  testWidgets('a running event shows its name, elapsed time and a stop control',
      (tester) async {
    await tester.pumpWidget(host(LifeEventState(event: running())));

    expect(find.text('Sauna'), findsOneWidget);
    expect(find.textContaining('23 min'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
  });

  testWidgets('a running event hides the type picker so there is one action',
      (tester) async {
    await tester.pumpWidget(host(LifeEventState(event: running())));

    expect(find.text('Alcohol'), findsNothing);
  });

  testWidgets('before any check-in it says it is watching, not that all is well',
      (tester) async {
    await tester.pumpWidget(
        host(LifeEventState(event: running(), acknowledged: true)));

    expect(find.textContaining('Watching'), findsOneWidget);
  });

  testWidgets('a check-in renders its summary', (tester) async {
    await tester.pumpWidget(host(
      LifeEventState(event: running(), checkIns: [aCheckIn()]),
    ));

    expect(
      find.text('Your heart rate is 18 bpm above your usual 62.'),
      findsOneWidget,
    );
  });

  testWidgets('an escalation is stated in words, not colour alone', (tester) async {
    await tester.pumpWidget(host(
      LifeEventState(event: running(), checkIns: [aCheckIn(escalate: true)]),
    ));

    expect(find.textContaining('medical'), findsOneWidget);
  });

  testWidgets('the closing analysis is shown once the event ends', (tester) async {
    await tester.pumpWidget(host(LifeEventState(
      analysis: EventCheckIn(
        eventId: 'e1',
        kind: EventPredictionKind.analysis,
        summary: 'During your sauna session, heart rate averaged 79.8 bpm.',
        createdAt: DateTime.now().toUtc(),
      ),
    )));

    expect(
      find.textContaining('heart rate averaged 79.8 bpm'),
      findsOneWidget,
    );
  });

  testWidgets('an error is shown plainly instead of failing silently',
      (tester) async {
    await tester.pumpWidget(
        host(const LifeEventState(error: 'Could not start. Check your connection.')));

    expect(find.text('Could not start. Check your connection.'), findsOneWidget);
  });
}
