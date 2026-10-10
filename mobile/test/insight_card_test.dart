import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/insights/models/clinical_insight.dart';
import 'package:telomy/features/insights/widgets/insight_card.dart';

/// What the card has to make unmistakable.
///
/// One distinction carries the whole phase: either a named clinician read these
/// exact words and signed them, or nobody did. Everything upstream — the absent
/// select policy, the signing-time licence check, the hash gate — exists to
/// make that true in the database. This is where it becomes true on a screen,
/// and the two most expensive mistakes available are showing a reviewer who did
/// not review, and burying the fact that nobody did.

Map<String, dynamic> row({
  String route = 'clinician_signed',
  String? reviewer = 'Dr A. Example',
  String? registration = 'MCI-TEST-0001',
  String? reviewedAt = '2026-10-09T10:00:00Z',
  String? disputedAt,
  String? dismissedAt,
}) => {
      'id': 'f1',
      'kind': 'lab_finding',
      'title': 'HbA1c has risen across 3 results',
      'body': 'HbA1c has risen 11.1%, from 5.4% on 12 February 2026 to '
          '6.0% on 30 September 2026.',
      'evidence': [
        {
          'biomarker_id': 'hba1c',
          'value_canonical': 5.4,
          'unit_canonical': '%',
          'collected_at': '2026-02-12',
          'lab_name': 'Test Labs',
        },
        {
          'biomarker_id': 'hba1c',
          'value_canonical': 6.0,
          'unit_canonical': '%',
          'collected_at': '2026-09-30',
          'lab_name': 'Test Labs',
        },
      ],
      'noticed_by': 'agent',
      'reviewed_at': reviewedAt,
      'reviewer_name': reviewer,
      'reviewer_registration': registration,
      'delivery_route': route,
      'delivered_at': '2026-10-09T10:00:05Z',
      'disputed_at': disputedAt,
      'dispute_reason': disputedAt == null ? null : 'My doctor already knows.',
      'dismissed_at': dismissedAt,
    };

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> pumpCard(
  WidgetTester tester,
  Map<String, dynamic> data, {
  void Function(String)? onDispute,
  VoidCallback? onDismiss,
}) async {
  await tester.pumpWidget(host(SingleChildScrollView(
    child: InsightCard(
      insight: ClinicalInsight.fromRow(data),
      onDispute: onDispute ?? (_) {},
      onDismiss: onDismiss ?? () {},
    ),
  )));
}

void main() {
  group('a signed finding', () {
    testWidgets('names the clinician and their registration', (tester) async {
      // "A doctor reviewed this" is unverifiable. A name and a registration
      // number is the claim we are actually making, and the only part of the
      // trail the user cannot reconstruct for themselves.
      await pumpCard(tester, row());

      expect(find.textContaining('Dr A. Example'), findsOneWidget);
      expect(find.textContaining('MCI-TEST-0001'), findsOneWidget);
    });

    testWidgets('says in words that a clinician reviewed it', (tester) async {
      await pumpCard(tester, row());

      expect(find.textContaining('Reviewed'), findsOneWidget);
    });

    testWidgets('shows the body exactly as signed', (tester) async {
      // A clinician put their registration number against these words. The app
      // does not summarise, truncate or rephrase them.
      await pumpCard(tester, row());

      expect(
        find.text('HbA1c has risen 11.1%, from 5.4% on 12 February 2026 to '
            '6.0% on 30 September 2026.'),
        findsOneWidget,
      );
    });
  });

  group('a finding nobody reviewed', () {
    testWidgets('says so plainly rather than staying quiet', (tester) async {
      // The SLA released this because the queue stalled. Saying nothing would
      // let the user assume the same review the signed cards carry.
      await pumpCard(tester, row(
        route: 'sla_expired',
        reviewer: null,
        registration: null,
        reviewedAt: null,
      ));

      expect(find.textContaining('Not yet reviewed'), findsOneWidget);
    });

    testWidgets('does not claim a reviewer', (tester) async {
      await pumpCard(tester, row(
        route: 'sla_expired',
        reviewer: null,
        registration: null,
        reviewedAt: null,
      ));

      expect(find.textContaining('Reviewed by'), findsNothing);
      expect(find.textContaining('Dr'), findsNothing);
    });

    testWidgets('states the status in words, not colour alone', (tester) async {
      // Colour alone fails for colour-blind users, and this particular
      // distinction is the one that must never be carried by a hue.
      await pumpCard(tester, row(
        route: 'sla_expired',
        reviewer: null,
        registration: null,
        reviewedAt: null,
      ));

      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .join(' ');
      expect(labels.toLowerCase(), contains('not yet reviewed'));
    });
  });

  group('the evidence', () {
    testWidgets('shows the values the finding rests on', (tester) async {
      await pumpCard(tester, row());

      // The exact evidence line, not just the number: the value also appears
      // inside the signed body, and matching loosely would pass on that alone
      // while the evidence section was missing entirely.
      expect(
        find.text('HbA1c 5.4% · 12 February 2026 · Test Labs'),
        findsOneWidget,
      );
      expect(
        find.text('HbA1c 6.0% · 30 September 2026 · Test Labs'),
        findsOneWidget,
      );
    });

    testWidgets('says what the finding is based on', (tester) async {
      await pumpCard(tester, row());

      expect(find.text('Based on'), findsOneWidget);
    });

    testWidgets('names the marker the way a lab report does', (tester) async {
      // F4 shipped "Rdw" and "Hs crp" to a real screen. A biomarker_id is not
      // a label.
      await pumpCard(tester, row());

      expect(find.textContaining('HbA1c'), findsWidgets);
      expect(find.textContaining('Hba1c'), findsNothing);
    });
  });

  group('responding to it', () {
    testWidgets('dismiss and dispute are separate actions', (tester) async {
      // Collapsing them would lose the distinction: "I have read this" and
      // "this is wrong about me" are different things to tell us, and only one
      // of them is a reason to look again.
      await pumpCard(tester, row());

      expect(find.text('Dismiss'), findsOneWidget);
      expect(find.text('This is wrong'), findsOneWidget);
    });

    testWidgets('dismissing reports it once', (tester) async {
      var dismissed = 0;
      await pumpCard(tester, row(), onDismiss: () => dismissed++);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();

      expect(dismissed, 1);
    });

    testWidgets('disputing asks for a reason before sending', (tester) async {
      // A dispute with no reason is a dismissal with a different label, and the
      // database requires a reason anyway — asking here is better than a
      // constraint violation the user cannot interpret.
      String? reason;
      await pumpCard(tester, row(), onDispute: (r) => reason = r);

      await tester.tap(find.text('This is wrong'));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(reason, isNull);
    });

    testWidgets('a dispute with a reason is sent', (tester) async {
      String? reason;
      await pumpCard(tester, row(), onDispute: (r) => reason = r);

      await tester.tap(find.text('This is wrong'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'My doctor already knows.');
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      expect(reason, 'My doctor already knows.');
    });

    testWidgets('an empty reason is not sent', (tester) async {
      String? reason;
      await pumpCard(tester, row(), onDispute: (r) => reason = r);

      await tester.tap(find.text('This is wrong'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      expect(reason, isNull);
    });

    testWidgets('an already disputed finding shows the dispute', (tester) async {
      await pumpCard(tester, row(disputedAt: '2026-10-09T12:00:00Z'));

      expect(find.textContaining('You said this is wrong'), findsOneWidget);
      expect(find.textContaining('My doctor already knows.'), findsOneWidget);
    });

    testWidgets('an already disputed finding cannot be disputed again',
        (tester) async {
      await pumpCard(tester, row(disputedAt: '2026-10-09T12:00:00Z'));

      expect(find.text('This is wrong'), findsNothing);
    });

    testWidgets('a reviewed finding says the dispute reaches its reviewer',
        (tester) async {
      await pumpCard(tester, row());

      await tester.tap(find.text('This is wrong'));
      await tester.pumpAndSettle();

      expect(find.textContaining('the clinician who reviewed it'),
          findsOneWidget);
    });

    testWidgets('an unreviewed finding does not promise a reviewer',
        (tester) async {
      // Found on a device: the helper text said "goes to the clinician who
      // reviewed it" on a card whose own badge said nobody had. The unreviewed
      // case is where a dispute matters most, and promising a reviewer who
      // does not exist is the same false claim the badge prevents.
      await pumpCard(tester, row(
        route: 'sla_expired',
        reviewer: null,
        registration: null,
        reviewedAt: null,
      ));

      await tester.tap(find.text('This is wrong'));
      await tester.pumpAndSettle();

      expect(find.textContaining('who reviewed it'), findsNothing);
      expect(find.textContaining('who picks it up'), findsOneWidget);
    });
  });

  group('malformed data', () {
    testWidgets('an empty insight renders without throwing', (tester) async {
      // Someone may open this screen in a bad network state. A render failure
      // must not be what hides a signed finding.
      await pumpCard(tester, {});

      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty insight is not presented as reviewed', (tester) async {
      await pumpCard(tester, {});

      expect(find.textContaining('Reviewed by'), findsNothing);
    });
  });
}
