import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/correlations/data/correlation_repository.dart';
import 'package:telomy/features/correlations/models/correlation.dart';

/// Reading correlations, and what the phone is allowed to do with them.
///
/// The phone computed these itself until F8: forty-five pairs, no
/// multiple-comparison correction, five matching days accepted, and a
/// "Strong pattern" label printed from the coefficient alone. Every test here
/// is about the phone no longer being in a position to do that.

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

Map<String, dynamic> pair({
  String id = 'hrv__sleep_duration',
  String first = 'hrv',
  String second = 'sleep_duration',
  double? coefficient = 0.62,
  int pairedDays = 58,
  double? effectiveDays = 31.4,
  double? pValue = 0.0004,
  String? mechanism,
  bool reviewed = false,
  String? withheld,
}) =>
    {
      'pair_id': id,
      'first': first,
      'second': second,
      'coefficient': coefficient,
      'paired_days': pairedDays,
      'effective_days': effectiveDays,
      'p_value': pValue,
      'expected_direction': 'positive',
      'mechanism': mechanism,
      'citation': null,
      'mechanism_reviewed': reviewed,
      'withheld': withheld,
    };

Map<String, dynamic> reportBody({
  List<Map<String, dynamic>>? reported,
  List<Map<String, dynamic>>? withheld,
  int tested = 5,
}) =>
    {
      'model_version': 'correlation-v2',
      'pairs_version': 'correlations.v1',
      'window_days': 90,
      'tested': tested,
      'reported': reported ?? [pair()],
      'withheld': withheld ?? const [],
    };

CorrelationRepository repositoryWith(StubAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000'));
  dio.httpClientAdapter = adapter;
  return CorrelationRepository(http: dio);
}

void main() {
  test('the window is asked for and the report comes back', () async {
    final adapter = StubAdapter();

    final report = await repositoryWith(adapter).fetch(days: 60);

    expect(adapter.lastRequest!.path, '/api/v1/correlations');
    expect(adapter.lastRequest!.queryParameters, {'days': 60});
    expect(report.reported.single.pairId, 'hrv__sleep_duration');
    expect(report.tested, 5);
  });

  test('an unsigned mechanism arrives as null and the pattern still does',
      () async {
    final report = await repositoryWith(StubAdapter()).fetch();

    expect(report.reported.single.mechanism, isNull);
    expect(report.reported.single.mechanismReviewed, isFalse);
    expect(report.reported.single.coefficient, 0.62);
  });

  test('a signed mechanism is carried through', () async {
    final adapter = StubAdapter(
      body: reportBody(reported: [pair(mechanism: 'Vagal tone.', reviewed: true)]),
    );

    final report = await repositoryWith(adapter).fetch();

    expect(report.reported.single.mechanism, 'Vagal tone.');
    expect(report.reported.single.mechanismReviewed, isTrue);
  });

  test('nothing reportable is an empty report, not an error', () async {
    final adapter = StubAdapter(body: reportBody(reported: const [], tested: 5));

    final report = await repositoryWith(adapter).fetch();

    expect(report.isEmpty, isTrue);
    expect(report.tested, 5);
  });

  test('offline says the server works these out, and offers nothing local',
      () async {
    final adapter = StubAdapter()..throws = DioExceptionType.connectionError;

    await expectLater(
      repositoryWith(adapter).fetch(),
      throwsA(
        isA<CorrelationsUnavailable>().having(
          (e) => e.message,
          'message',
          allOf(contains('No connection'), contains('not on this phone')),
        ),
      ),
    );
  });

  test('a build with no service configured says so rather than guessing',
      () async {
    await expectLater(
      CorrelationRepository().fetch(),
      throwsA(isA<CorrelationsUnavailable>()),
    );
  });

  test('a withheld pair carries its reason', () async {
    final adapter = StubAdapter(
      body: reportBody(
        reported: const [],
        withheld: [pair(withheld: 'direction_mismatch')],
      ),
    );

    final report = await repositoryWith(adapter).fetch();

    expect(report.withheld.single.isReported, isFalse);
    expect(
      withheldReason(report.withheld.single.withheld!, 90),
      contains('opposite'),
    );
  });

  test('HRV is labelled HRV and not Hrv', () {
    // F4 shipped "Rdw" and "Hs crp" to a real screen with every test green.
    expect(seriesLabel('hrv'), 'HRV');
    expect(seriesLabel('resting_heart_rate'), 'Resting heart rate');
  });

  test('an unknown series id renders as itself rather than crashing', () {
    expect(seriesLabel('something_new'), 'something_new');
  });

  test('every reason the server can withhold for has words for a person', () {
    for (final reason in [
      'too_few_days',
      'weak',
      'not_significant',
      'direction_mismatch',
    ]) {
      expect(withheldReason(reason, 90), isNot('Not reportable.'));
    }
  });
}
