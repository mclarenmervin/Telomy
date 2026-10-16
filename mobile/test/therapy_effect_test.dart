import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:telomy/features/therapies/data/therapy_repository.dart';
import 'package:telomy/features/therapies/models/therapy_effect.dart';
import 'package:telomy/features/therapies/widgets/therapy_effects_section.dart';

/// Reading back what a run of sessions did.
///
/// The therapy screen has always been a list of things the user typed. These
/// are about the half that reads them back, and about the phone not being in
/// a position to decide any of it.

class StubAdapter implements HttpClientAdapter {
  StubAdapter({this.status = 200, Map<String, dynamic>? body})
      : body = body ?? reportBody();

  int status;
  Map<String, dynamic> body;
  RequestOptions? lastRequest;
  DioExceptionType? throws;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    if (throws != null) {
      throw DioException(requestOptions: options, type: throws!);
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> effect({
  String modality = 'sauna',
  String metric = 'heartRate',
  double? meanDelta = 17.0,
  int sessions = 8,
  int confounded = 0,
  String? mechanism,
  bool reviewed = false,
  String? withheld,
  String verdict = 'helped',
}) =>
    {
      'modality': modality,
      'label': modality == 'sauna' ? 'sauna' : 'cold plunge',
      'metric': metric,
      'mean_delta': meanDelta,
      'sessions': sessions,
      'sessions_confounded': confounded,
      'p_value': 0.0004,
      'expected_direction': 'increase',
      'mechanism': mechanism,
      'citation': null,
      'mechanism_reviewed': reviewed,
      'withheld': withheld,
      'verdict': verdict,
      'ci_low': meanDelta == null ? null : meanDelta - 2,
      'ci_high': meanDelta == null ? null : meanDelta + 2,
      'q_value': 0.02,
      'replicated': verdict == 'helped',
      'wearable_coverage': meanDelta == null ? 0.0 : 1.0,
      'next_milestone': 'Keep recording sessions.',
      'provenance': {'model_version': 'therapy-effect-v2'},
    };

Map<String, dynamic> reportBody({
  List<Map<String, dynamic>>? reported,
  List<Map<String, dynamic>>? withheld,
  int tested = 1,
}) =>
    {
      'model_version': 'therapy-effect-v1',
      'catalog_version': 'therapies.v1',
      'min_sessions': 5,
      'tested': tested,
      'reported': reported ?? [effect()],
      'withheld': withheld ?? const [],
      'verdicts': reported ?? [effect()],
    };

TherapyRepository repositoryWith(StubAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000'));
  dio.httpClientAdapter = adapter;
  return TherapyRepository(http: dio);
}

void main() {
  test('a run of sessions comes back as a change', () async {
    final adapter = StubAdapter();

    final report = await repositoryWith(adapter).effects();

    expect(adapter.lastRequest!.path, '/api/v1/therapies/effects');
    expect(report.reported.single.meanDelta, 17.0);
    expect(report.reported.single.sessions, 8);
    expect(report.reported.single.rose, isTrue);
  });

  test('an unsigned mechanism arrives null and the change still does',
      () async {
    final report = await repositoryWith(StubAdapter()).effects();

    expect(report.reported.single.mechanism, isNull);
    expect(report.reported.single.mechanismReviewed, isFalse);
  });

  test('a fall is a fall and not a negative rise', () async {
    final adapter = StubAdapter(
      body: reportBody(reported: [effect(meanDelta: -6.2, metric: 'hrv')]),
    );

    final report = await repositoryWith(adapter).effects();

    expect(report.reported.single.rose, isFalse);
    expect(report.reported.single.meanDelta, -6.2);
  });

  test('three sessions is a result and not an error', () async {
    final adapter = StubAdapter(
      body: reportBody(
        reported: const [],
        withheld: [effect(sessions: 3, withheld: 'too_few_sessions')],
      ),
    );

    final report = await repositoryWith(adapter).effects();

    expect(report.isEmpty, isTrue);
    expect(
      therapyWithheldReason(report.withheld.single.withheld!, 5),
      contains('5 sessions'),
    );
  });

  test('confounded sessions are carried so the count can be explained',
      () async {
    final adapter = StubAdapter(
      body: reportBody(reported: [effect(sessions: 7, confounded: 2)]),
    );

    final report = await repositoryWith(adapter).effects();

    expect(report.reported.single.sessionsConfounded, 2);
  });

  test('offline says the server works this out and offers nothing local',
      () async {
    final adapter = StubAdapter()..throws = DioExceptionType.connectionError;

    await expectLater(
      repositoryWith(adapter).effects(),
      throwsA(isA<TherapyEffectsUnavailable>().having(
        (e) => e.message, 'message', contains('not on this phone'))),
    );
  });

  test('HRV is labelled HRV and spo2 is words', () {
    expect(metricLabel('hrv'), 'HRV');
    expect(metricLabel('spo2'), 'Blood oxygen');
    expect(metricLabel('heartRate'), 'Heart rate');
  });

  test('every metric the engine tracks has a label and a unit', () {
    // Matching app/analytics/event_analysis.py TRACKED.
    for (final metric in ['heartRate', 'hrv', 'temperature', 'spo2']) {
      expect(metricLabels.containsKey(metric), isTrue, reason: metric);
      expect(metricUnits.containsKey(metric), isTrue, reason: metric);
    }
  });

  test('every reason the server can withhold for has words for a person', () {
    for (final reason in [
      'too_few_sessions',
      'not_significant',
      'direction_mismatch',
    ]) {
      expect(therapyWithheldReason(reason, 5), isNot('Not reportable.'));
    }
  });

  test('an unknown verdict is refused instead of being upgraded to helped', () {
    expect(
      () => TherapyEffect.fromJson(effect(verdict: 'future_verdict')),
      throwsFormatException,
    );
  });

  testWidgets('all six honest verdicts have dedicated non-causal presentation', (tester) async {
    for (final verdict in TherapyVerdict.values) {
      final model = TherapyEffect.fromJson(effect(
        verdict: verdict.wire,
        meanDelta: verdict == TherapyVerdict.inSessionOnly ? null : 3,
      ));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: TherapyVerdictCard(effect: model))));
      expect(find.text(therapyVerdictTitle(verdict)), findsOneWidget, reason: verdict.wire);
      expect(find.textContaining('not proof of cause'), findsOneWidget);
      expect(find.textContaining('Keep recording sessions'), findsOneWidget);
    }
  });
}
