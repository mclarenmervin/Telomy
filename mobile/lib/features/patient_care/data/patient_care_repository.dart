import 'package:dio/dio.dart';

import '../models/patient_care.dart';

class PatientCareUnavailable implements Exception {
  const PatientCareUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

class PatientCareRepository {
  PatientCareRepository({required Dio http}) : _http = http;
  final Dio _http;

  Future<PatientCare> read() async {
    try {
      final response = await _http.get<dynamic>('/api/v1/account/care');
      if (response.statusCode != 200 || response.data is! Map) {
        throw const PatientCareUnavailable(
          'Your care team could not be loaded.',
        );
      }
      return PatientCare.fromJson(
        (response.data as Map).cast<String, dynamic>(),
      );
    } on PatientCareUnavailable {
      rethrow;
    } on DioException {
      throw const PatientCareUnavailable(
        'Your care team could not be reached just now.',
      );
    }
  }

  Future<void> setConsent(String centreId, bool granted) async {
    try {
      final response = await _http.post<dynamic>(
        '/api/v1/account/care/$centreId/consent',
        data: {'granted': granted},
      );
      if (response.statusCode != 200) {
        throw const PatientCareUnavailable(
          'Your consent choice could not be saved.',
        );
      }
    } on PatientCareUnavailable {
      rethrow;
    } on DioException {
      throw const PatientCareUnavailable(
        'Your consent choice could not be saved.',
      );
    }
  }
}
