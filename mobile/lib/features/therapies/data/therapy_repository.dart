import 'package:dio/dio.dart';

import '../models/therapy_effect.dart';

class TherapyEffectsUnavailable implements Exception {
  const TherapyEffectsUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reading what this person's own therapy sessions did to them.
///
/// No local fallback, for the same reason the correlations screen has none:
/// the phone is not in a position to decide how many sessions make evidence
/// or whether a change ran the way the therapy is supposed to.
class TherapyRepository {
  TherapyRepository({Dio? http}) : _http = http;

  final Dio? _http;

  Future<TherapyEffectReport> effects() async {
    final http = _http;
    if (http == null) {
      throw const TherapyEffectsUnavailable(
        'This is worked out by the Telomy service, which this build is not '
        'pointed at.',
      );
    }

    final Response<dynamic> response;
    try {
      response = await http.get(
        '/api/v1/therapies/effects',
        options:
            Options(validateStatus: (status) => status != null && status < 500),
      );
    } on DioException catch (_) {
      throw const TherapyEffectsUnavailable(
        'No connection, so we could not work this out. It is calculated from '
        'your full history on the server, not on this phone.',
      );
    }

    if (response.statusCode != 200) {
      throw const TherapyEffectsUnavailable(
        'This could not be worked out just now.',
      );
    }

    final body = response.data is Map
        ? Map<String, dynamic>.from(response.data as Map)
        : const <String, dynamic>{};
    return TherapyEffectReport.fromJson(body);
  }
}
