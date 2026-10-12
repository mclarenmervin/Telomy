import 'package:dio/dio.dart';
import '../models/centre_roster.dart';

class CentreUnavailable implements Exception {
  const CentreUnavailable(this.message);
  final String message;
}

class CentreRepository {
  CentreRepository({required Dio http}) : _http = http;
  final Dio _http;
  Future<List<CentreRef>> mine() async => [
    for (final row in await _items('/api/v1/centre/mine'))
      CentreRef.fromJson(row),
  ];
  Future<List<CentrePerson>> doctors(String id) async => [
    for (final row in await _items('/api/v1/centre/$id/doctors'))
      CentrePerson.fromJson(row),
  ];
  Future<List<CentrePerson>> patients(String id) async => [
    for (final row in await _items('/api/v1/centre/$id/patients'))
      CentrePerson.fromJson(row),
  ];
  Future<void> invite({
    required String centreId,
    required String email,
    required String role,
    String? primaryDoctorId,
  }) => _write(
    'POST',
    '/api/v1/centre/$centreId/invitations',
    {
      'email': email,
      'intended_role': role,
      'primary_doctor_id': primaryDoctorId,
    },
    headers: {
      'Idempotency-Key': '${DateTime.now().microsecondsSinceEpoch}-$email',
    },
  );
  Future<void> assign({
    required String centreId,
    required String patientId,
    required String doctorId,
    bool primary = false,
  }) => _write(
    'POST',
    '/api/v1/centre/$centreId/patients/$patientId/assignments',
    {'doctor_id': doctorId, 'primary': primary},
  );
  Future<void> setPrimary({
    required String centreId,
    required String patientId,
    required String doctorId,
  }) => _write(
    'PATCH',
    '/api/v1/centre/$centreId/patients/$patientId/primary-doctor',
    {'doctor_id': doctorId},
  );
  Future<List<Map<String, dynamic>>> _items(String path) async {
    final data = await _request('GET', path);
    return [
      for (final row in ((data as Map)['items'] as List? ?? const []))
        (row as Map).cast<String, dynamic>(),
    ];
  }

  Future<void> _write(
    String method,
    String path,
    Map<String, dynamic> body, {
    Map<String, dynamic>? headers,
  }) async {
    await _request(method, path, data: body, headers: headers);
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? headers,
  }) async {
    try {
      final response = await _http.request<dynamic>(
        path,
        data: data,
        options: Options(
          method: method,
          headers: headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      if ((response.statusCode ?? 500) >= 400) {
        throw const CentreUnavailable('This centre action is not permitted.');
      }
      return response.data;
    } on CentreUnavailable {
      rethrow;
    } on DioException {
      throw const CentreUnavailable('The centre service is unavailable.');
    }
  }
}
