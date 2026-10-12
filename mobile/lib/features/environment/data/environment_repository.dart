import 'package:dio/dio.dart';

import '../models/environment_snapshot.dart';

class EnvironmentUnavailable implements Exception {
  const EnvironmentUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reading the air and the sun where this person said they were.
///
/// Over REST rather than straight from the table, unlike most reads in this
/// app, for one reason: the AQI and UV bands are computed, and computing
/// them here would be a second implementation of a published scale.
class EnvironmentRepository {
  EnvironmentRepository({Dio? http}) : _http = http;

  final Dio? _http;

  Future<List<EnvironmentSnapshot>> recent({int days = 14}) async {
    final http = _http;
    if (http == null) {
      throw const EnvironmentUnavailable(
        'This is looked up by the Telomy service, which this build is not '
        'pointed at.',
      );
    }

    final Response<dynamic> response;
    try {
      response = await http.get(
        '/api/v1/environment',
        queryParameters: {'days': days},
        options:
            Options(validateStatus: (status) => status != null && status < 500),
      );
    } on DioException catch (_) {
      throw const EnvironmentUnavailable(
        'No connection, so we could not look this up.',
      );
    }

    if (response.statusCode != 200) {
      throw const EnvironmentUnavailable('This could not be looked up just now.');
    }

    final body = response.data is Map
        ? Map<String, dynamic>.from(response.data as Map)
        : const <String, dynamic>{};
    return [
      for (final row in (body['items'] as List? ?? const []))
        EnvironmentSnapshot.fromRow(Map<String, dynamic>.from(row as Map)),
    ];
  }
}
