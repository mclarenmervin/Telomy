import 'package:dio/dio.dart';

import '../models/correlation.dart';

/// Something stopped the patterns being worked out, phrased for a person.
class CorrelationsUnavailable implements Exception {
  const CorrelationsUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reading this person's correlations.
///
/// **There is no local fallback, deliberately.** Readiness has one, because a
/// frozen local model is a legitimate approximation of the server's and the
/// two can be compared. Correlations do not: the version this replaced tested
/// forty-five pairs with no multiple-comparison correction from as few as five
/// matching days, so falling back to it on a train would mean showing somebody
/// statistically false patterns about their own body — precisely the thing the
/// rewrite exists to stop. Offline, the honest answer is that we cannot work
/// these out right now.
class CorrelationRepository {
  CorrelationRepository({Dio? http}) : _http = http;

  final Dio? _http;

  Future<CorrelationReport> fetch({int days = 90}) async {
    final http = _http;
    if (http == null) {
      throw const CorrelationsUnavailable(
        'Patterns are worked out by the Telomy service, which this build is '
        'not pointed at.',
      );
    }

    final Response<dynamic> response;
    try {
      response = await http.get(
        '/api/v1/correlations',
        queryParameters: {'days': days},
        options: Options(validateStatus: (status) => status != null && status < 500),
      );
    } on DioException catch (error) {
      throw CorrelationsUnavailable(_offlineMessage(error));
    }

    if (response.statusCode != 200) {
      throw const CorrelationsUnavailable(
        'These patterns could not be worked out just now.',
      );
    }

    final body = response.data is Map
        ? Map<String, dynamic>.from(response.data as Map)
        : const <String, dynamic>{};
    return CorrelationReport.fromJson(body);
  }

  String _offlineMessage(DioException error) => switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout =>
          'That took too long to come back. Please try again.',
        DioExceptionType.connectionError =>
          'No connection, so these could not be worked out. They are '
              'calculated from your full history on the server, not on this '
              'phone.',
        _ => 'These patterns could not be worked out just now.',
      };
}
