import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/app/role_routes.dart';
import 'package:telomy/features/centre/data/centre_repository.dart';
import 'package:telomy/features/roles/models/app_role.dart';

class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.handler);
  final ResponseBody Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody response(Object value, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(value),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

void main() {
  test(
    'centre repository keeps roster and assignment paths centre-scoped',
    () async {
      final requests = <String>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost'))
        ..httpClientAdapter = StubAdapter((options) {
          requests.add('${options.method} ${options.path}');
          if (options.path.endsWith('/doctors') ||
              options.path.endsWith('/patients')) {
            return response({'items': []});
          }
          return response({'id': 'a1'}, status: 201);
        });
      final repo = CentreRepository(http: dio);
      await repo.doctors('c1');
      await repo.patients('c1');
      await repo.assign(
        centreId: 'c1',
        patientId: 'p1',
        doctorId: 'd1',
        primary: true,
      );
      await repo.setPrimary(centreId: 'c1', patientId: 'p1', doctorId: 'd2');
      expect(requests, [
        'GET /api/v1/centre/c1/doctors',
        'GET /api/v1/centre/c1/patients',
        'POST /api/v1/centre/c1/patients/p1/assignments',
        'PATCH /api/v1/centre/c1/patients/p1/primary-doctor',
      ]);
    },
  );

  test('centre shell names the five management branches', () {
    expect(roleTabs(AppRole.centre).map((tab) => tab.label), [
      'Dashboard',
      'Doctors',
      'Patients',
      'Assignments',
      'Profile',
    ]);
  });
}
