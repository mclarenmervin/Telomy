import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/activity_report/models/activity_report.dart';
import 'package:telomy/features/activity_report/widgets/activity_report_card.dart';

ActivityReport reportWith({
  String severity = 'normal',
  List<ReportMetric> metrics = const [],
  ReportEscalation escalation = ReportEscalation.routine,
}) => ActivityReport(
  sessionId: 's1',
  eventType: 'cycling',
  headline: 'A steady ride.',
  sections: const [],
  metrics: metrics,
  dataQuality: 'full',
  sessionsCompared: 5,
  severity: severity,
  escalation: escalation,
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('a flagged metric shows the word, not colour alone', (tester) async {
    await tester.pumpWidget(host(ReportBody(
      report: reportWith(severity: 'attention', metrics: const [
        ReportMetric(key: 'spo2', value: 93, baseline: 97, delta: -4,
                     direction: 'worse', severity: 'attention',
                     note: 'Dipped below your usual range.'),
      ]),
    )));

    expect(find.text('Blood oxygen'), findsOneWidget);
    expect(find.text('Dipped below your usual range.'), findsOneWidget);
    // Colour alone fails for colour-blind users; the word must be present.
    expect(find.text('attention'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('all reported metrics render, not just four', (tester) async {
    await tester.pumpWidget(host(ReportBody(
      report: reportWith(metrics: const [
        ReportMetric(key: 'heartRate', value: 129, note: 'a'),
        ReportMetric(key: 'hrv', value: 51, note: 'b'),
        ReportMetric(key: 'spo2', value: 98, note: 'c'),
        ReportMetric(key: 'stress', value: 42, note: 'd'),
        ReportMetric(key: 'steps', value: 4000, note: 'e'),
      ]),
    )));

    for (final label in ['Heart rate', 'HRV', 'Blood oxygen', 'Stress', 'Steps']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('a normal metric shows no severity word', (tester) async {
    await tester.pumpWidget(host(ReportBody(
      report: reportWith(metrics: const [
        ReportMetric(key: 'steps', value: 4000, note: 'Steady volume.'),
      ]),
    )));

    expect(find.text('attention'), findsNothing);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('a routine escalation is a quiet link', (tester) async {
    await tester.pumpWidget(host(ReportBody(
      report: reportWith(escalation: const ReportEscalation(
        level: 'routine', title: 'Book a consultation',
        body: 'Whenever you want to.', action: 'book_consultation')),
    )));

    expect(find.text('Book a consultation'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('a recommended escalation is prominent and names the reason',
      (tester) async {
    await tester.pumpWidget(host(ReportBody(
      report: reportWith(severity: 'attention', escalation: const ReportEscalation(
        level: 'recommended', title: 'Worth getting checked',
        body: 'One of your readings moved outside your usual range.',
        action: 'book_consultation')),
    )));

    expect(find.text('Worth getting checked'), findsOneWidget);
    expect(find.text('One of your readings moved outside your usual range.'),
        findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });

  testWidgets('a report with no escalation field still offers the routine route',
      (tester) async {
    // Spec 11: a v1 report must not strand the user without a booking route.
    await tester.pumpWidget(host(ReportBody(report: reportWith())));

    expect(find.text('Book a consultation'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('no escalation copy ever contains a phone number', (tester) async {
    await tester.pumpWidget(host(ReportBody(
      report: reportWith(severity: 'urgent', escalation: const ReportEscalation(
        level: 'urgent', title: 'Please get this checked',
        body: 'Please arrange to see a practitioner.',
        action: 'book_consultation')),
    )));

    final texts = tester.widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join(' ');
    expect(RegExp(r'\+?\d[\d\s().-]{6,}').hasMatch(texts), isFalse);
  });

  testWidgets('a flagged metric row fits a real phone at accessible text scale',
      (tester) async {
    // 393dp is a Pixel/iPhone 14; 1.3 is an ordinary accessibility setting. The
    // severity word is the signal spec D7 says must not be missed, so it must not
    // be clipped. The default 800x600 test surface hid this.
    tester.view.physicalSize = const Size(393, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
      child: host(ReportBody(
        report: reportWith(severity: 'attention', metrics: const [
          ReportMetric(key: 'heartRate', value: 129.4, baseline: 136.6, delta: -7.2,
                       direction: 'better', severity: 'attention',
                       note: 'Moved outside your usual range.'),
        ]),
      )),
    ));

    expect(tester.takeException(), isNull);
    expect(find.text('attention'), findsOneWidget);
  });
}
