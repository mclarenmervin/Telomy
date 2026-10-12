import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/admin/data/admin_repository.dart';
import 'package:telomy/features/admin/screens/patient_viewer_screen.dart';

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
    'admin creates centres, invites every role and verifies doctors',
    () async {
      final requests = <String>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost'))
        ..httpClientAdapter = StubAdapter((options) {
          requests.add('${options.method} ${options.path}');
          if (options.path.endsWith('/centres')) {
            return response({'id': 'c1', 'name': 'North'}, status: 201);
          }
          if (options.path.contains('verification-decisions')) {
            return response({'id': 'v1', 'status': 'verified'}, status: 201);
          }
          return response({
            'invitation_id': 'i1',
            'status': 'pending',
          }, status: 201);
        });
      final repo = AdminRepository(http: dio);
      await repo.createCentre('North');
      for (final role in ['admin', 'centre', 'doctor', 'member']) {
        await repo.invite(
          email: '$role@example.com',
          role: role,
          centreId: role == 'admin' ? null : 'c1',
        );
      }
      await repo.verifyDoctor(
        doctorId: 'd1',
        status: 'verified',
        reason: 'licence checked',
        registrationNumber: 'R1',
        registrationBody: 'NMC',
        licenceExpiresAt: DateTime(2030),
      );
      expect(requests.where((r) => r.contains('/invitations')).length, 4);
      expect(
        requests.last,
        'POST /api/v1/admin/clinicians/d1/verification-decisions',
      );
    },
  );

  testWidgets(
    'admin patient viewer is visibly read-only with no clinical controls',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: PatientViewerScreen(
            patientId: 'p1',
            initialRecord: {
              'patient_id': 'p1',
              'drafts': [],
              'monthly_reports': [],
            },
          ),
        ),
      );
      expect(find.text('Read-only clinical record'), findsWidgets);
      expect(find.text('Sign'), findsNothing);
      expect(find.text('Edit'), findsNothing);
    },
  );
}
