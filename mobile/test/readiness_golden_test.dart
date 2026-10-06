import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/health/models/health_measurement.dart';
import 'package:telomy/features/readiness/data/readiness_service.dart';

/// Readiness parity fixtures — the Dart half.
///
/// The same files are run by healthagent/tests/test_readiness_golden.py. Two
/// independent implementations agreeing on these inputs is what makes "the port
/// is identical" a fact rather than a claim, and it is the precondition for
/// changing the model server-side.
///
/// A failure here means Python and Dart disagree. The fixture name says which
/// inputs to look at; do not "fix" it by regenerating the fixtures.
const tolerance = 1e-6;

Directory goldenDir() {
  for (final candidate in ['../golden/readiness', 'golden/readiness']) {
    final dir = Directory(candidate);
    if (dir.existsSync()) return dir;
  }
  throw StateError('golden/readiness not found from ${Directory.current.path}');
}

HealthMeasurement measurementFrom(Map<String, dynamic> json) => HealthMeasurement(
      id: 'fixture',
      userId: 'fixture',
      measurementType: MeasurementType.values.byName(json['measurement_type'] as String),
      value: (json['value'] as num).toDouble(),
      unit: '',
      // Parsed without an offset so both languages do identical day arithmetic.
      recordedAt: DateTime.parse(json['recorded_at'] as String),
      source: MeasurementSource.manual,
      quality: MeasurementQuality.measured,
      endedAt: json['ended_at'] == null
          ? null
          : DateTime.parse(json['ended_at'] as String),
    );

void main() {
  final files = goldenDir()
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('the golden fixtures are present', () {
    expect(files, isNotEmpty, reason: 'run scripts/build_readiness_golden.py');
  });

  for (final file in files) {
    final payload = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final name = payload['name'] as String;

    test('Dart matches the golden fixture: $name', () {
      final measurements = (payload['measurements'] as List)
          .map((m) => measurementFrom(m as Map<String, dynamic>))
          .toList();

      final result = const ReadinessService().calculate(
        measurements: measurements,
        date: DateTime.parse(payload['date'] as String),
        sleepGoal: (payload['sleep_goal'] as num).toDouble(),
        activityGoal: (payload['activity_goal'] as num).toDouble(),
      );
      final expected = payload['expected'] as Map<String, dynamic>;

      expect(result.score, expected['score'], reason: 'score for $name');
      expect(result.modelVersion, expected['model_version']);

      final missing = [...result.missingInputs]..sort();
      expect(missing, (expected['missing_inputs'] as List).cast<String>());

      final drivers = [...result.drivers]..sort((a, b) => a.name.compareTo(b.name));
      final wanted = (expected['drivers'] as List).cast<Map<String, dynamic>>();

      expect(drivers.map((d) => d.name).toList(),
          wanted.map((d) => d['name'] as String).toList());

      for (var i = 0; i < drivers.length; i++) {
        expect(drivers[i].score,
            closeTo((wanted[i]['score'] as num).toDouble(), tolerance),
            reason: '${drivers[i].name} score in $name');
        expect(drivers[i].weight,
            closeTo((wanted[i]['weight'] as num).toDouble(), tolerance),
            reason: '${drivers[i].name} weight in $name');
      }
    });
  }
}
