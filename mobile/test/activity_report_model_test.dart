import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/activity_report/models/activity_report.dart';

Map<String, dynamic> row(Map<String, dynamic> analysis) => {
  'kind': 'activity_summary',
  'event_id': 's1',
  'summary': 'x',
  'analysis': analysis,
  'guardrail_flags': <String>[],
};

void main() {
  test('parses severity, note and escalation from a v2 report', () {
    final report = ActivityReport.fromRow(row({
      'schema_version': 2,
      'headline': 'A steady ride.',
      'severity': 'attention',
      'sections': [],
      'metrics': [
        {'key': 'spo2', 'value': 93, 'baseline': 97, 'delta': -4,
         'direction': 'worse', 'severity': 'attention',
         'note': 'Dipped below your usual range.'},
      ],
      'escalation': {'level': 'recommended', 'title': 'Worth getting checked',
                     'body': 'Have someone look at it.', 'action': 'book_consultation'},
    }));

    expect(report!.severity, 'attention');
    expect(report.metrics.first.severity, 'attention');
    expect(report.metrics.first.note, 'Dipped below your usual range.');
    expect(report.escalation!.level, 'recommended');
    expect(report.escalation!.title, 'Worth getting checked');
    expect(report.escalation!.isProminent, isTrue);
  });

  test('a v1 report with no severity or escalation still parses', () {
    final report = ActivityReport.fromRow(row({
      'schema_version': 1,
      'headline': 'A steady ride.',
      'sections': [],
      'metrics': [{'key': 'heartRate', 'value': 129}],
    }));

    expect(report, isNotNull);
    expect(report!.severity, 'normal');
    expect(report.escalation, isNull);
    expect(report.metrics.first.severity, 'normal');
    expect(report.metrics.first.note, '');
  });

  test('a routine escalation is not prominent', () {
    final report = ActivityReport.fromRow(row({
      'headline': 'A steady ride.',
      'severity': 'normal',
      'sections': [],
      'metrics': [],
      'escalation': {'level': 'routine', 'title': 'Book a consultation',
                     'body': 'Whenever you want to.', 'action': 'book_consultation'},
    }));

    expect(report!.escalation!.isProminent, isFalse);
  });

  test('still accepts analysis delivered as a JSON string over Realtime', () {
    final asString = row({})
      ..['analysis'] = jsonEncode({
        'headline': 'A steady ride.',
        'severity': 'urgent',
        'sections': <dynamic>[],
        'metrics': <dynamic>[],
      });

    final report = ActivityReport.fromRow(asString);

    expect(report!.severity, 'urgent');
  });
}
