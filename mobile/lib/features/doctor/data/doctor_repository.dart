import 'package:dio/dio.dart';
import '../models/doctor_models.dart';

class DoctorUnavailable implements Exception {
  const DoctorUnavailable(this.message);
  final String message;
}

class DoctorRepository {
  DoctorRepository({required Dio http}) : _http = http;
  final Dio _http;
  Future<List<DoctorCentre>> centres() async => [
    for (final r in await _items('/api/v1/doctor/centres'))
      DoctorCentre.fromJson(r),
  ];
  Future<DoctorToday> today(String c) async => DoctorToday.fromJson(
    (await _request('GET', '/api/v1/doctor/$c/today') as Map)
        .cast<String, dynamic>(),
  );
  Future<List<DoctorPatient>> patients(String c, {String? query}) async => [
    for (final r in await _items(
      '/api/v1/doctor/$c/patients',
      query: query == null ? null : {'query': query},
    ))
      DoctorPatient.fromJson(r),
  ];
  Future<Map<String, dynamic>> patient(String c, String p) async =>
      (await _request('GET', '/api/v1/doctor/$c/patients/$p') as Map)
          .cast<String, dynamic>();
  Future<DoctorWorkQueue> workQueue(String c) async => DoctorWorkQueue.fromJson(
    (await _request('GET', '/api/v1/doctor/$c/work-queue') as Map)
        .cast<String, dynamic>(),
  );
  Future<Map<String, dynamic>> profile() async =>
      (await _request('GET', '/api/v1/doctor/profile') as Map)
          .cast<String, dynamic>();
  Future<void> addNote({
    required String centreId,
    required String patientId,
    required String body,
    String? supersedesId,
  }) => _write('/api/v1/doctor/$centreId/patients/$patientId/notes', {
    'body': body,
    'supersedes_id': supersedesId,
  });
  Future<void> claim({required String centreId, required String draftId}) =>
      _write('/api/v1/doctor/$centreId/work/$draftId/claim', {});
  Future<void> release({required String centreId, required String draftId}) =>
      _write('/api/v1/doctor/$centreId/work/$draftId/release', {});
  Future<void> signDraft({
    required String centreId,
    required String draftId,
    required String note,
    required String version,
    String? body,
  }) {
    if (note.trim().isEmpty) {
      return Future.error(ArgumentError('note is required'));
    }
    return _write('/api/v1/doctor/$centreId/work/$draftId/sign', {
      'note': note.trim(),
      'version': version,
      'body': body,
    });
  }

  Future<void> rejectDraft({
    required String centreId,
    required String draftId,
    required String note,
    required String version,
  }) {
    if (note.trim().isEmpty) {
      return Future.error(ArgumentError('note is required'));
    }
    return _write('/api/v1/doctor/$centreId/work/$draftId/reject', {
      'note': note.trim(),
      'version': version,
    });
  }

  Future<void> signReport({
    required String centreId,
    required String reportId,
    required String note,
    required String version,
  }) {
    if (note.trim().isEmpty) {
      return Future.error(ArgumentError('note is required'));
    }
    return _write('/api/v1/doctor/$centreId/reports/$reportId/sign', {
      'note': note.trim(),
      'version': version,
    });
  }

  Future<void> rejectReport({
    required String centreId,
    required String reportId,
    required String note,
    required String version,
  }) {
    if (note.trim().isEmpty) {
      return Future.error(ArgumentError('note is required'));
    }
    return _write('/api/v1/doctor/$centreId/reports/$reportId/reject', {
      'note': note.trim(),
      'version': version,
    });
  }

  Future<void> signTherapyPlan({
    required String centreId,
    required String planId,
    required String note,
    required String contentSha256,
  }) => _write('/api/v1/doctor/$centreId/therapy-plans/$planId/sign', {
    'note': note.trim(), 'content_sha256': contentSha256,
  });

  Future<List<Map<String, dynamic>>> _items(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final d = await _request('GET', path, query: query);
    return [
      for (final r in ((d as Map)['items'] as List? ?? []))
        (r as Map).cast<String, dynamic>(),
    ];
  }

  Future<void> _write(String path, Map<String, dynamic> body) async {
    await _request('POST', path, data: body);
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? query,
  }) async {
    try {
      final r = await _http.request<dynamic>(
        path,
        data: data,
        queryParameters: query,
        options: Options(
          method: method,
          validateStatus: (s) => s != null && s < 600,
        ),
      );
      if ((r.statusCode ?? 500) >= 400) {
        throw const DoctorUnavailable(
          'Doctor workspace is temporarily unavailable.',
        );
      }
      return r.data;
    } on DoctorUnavailable {
      rethrow;
    } on DioException {
      throw const DoctorUnavailable(
        'Doctor workspace is temporarily unavailable.',
      );
    }
  }
}
