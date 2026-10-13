import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/patient_care/data/patient_care_repository.dart';
import 'package:telomy/features/patient_care/models/patient_care.dart';
import 'package:telomy/features/patient_care/screens/patient_care_screen.dart';

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

ResponseBody jsonResponse(Object body) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

void main() {
  test(
    'repository reads self care and grants or revokes only centre consent',
    () async {
      final calls = <String>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost'));
      dio.httpClientAdapter = StubAdapter((options) {
        calls.add(
          '${options.method} ${options.path} ${options.data ?? ''}'.trim(),
        );
        return jsonResponse(
          options.method == 'GET'
              ? {
                  'centres': [
                    {
                      'id': 'c1',
                      'name': 'Telomy Bengaluru',
                      'doctors': [
                        {'id': 'd1', 'name': 'Dr Primary', 'is_primary': true},
                        {
                          'id': 'd2',
                          'name': 'Dr Additional',
                          'is_primary': false,
                        },
                      ],
                      'consent': {
                        'active': false,
                        'expires_at': '2026-10-01T00:00:00Z',
                        'history': [],
                      },
                    },
                  ],
                }
              : {'id': 'consent-1', 'active': true},
        );
      });
      final repository = PatientCareRepository(http: dio);
      final care = await repository.read();
      expect(care.centres.single.doctors.first.isPrimary, isTrue);
      expect(care.centres.single.consentExpired, isTrue);
      await repository.setConsent('c1', true);
      await repository.setConsent('c1', false);
      expect(calls.map((call) => call.split(' ').take(2).join(' ')), [
        'GET /api/v1/account/care',
        'POST /api/v1/account/care/c1/consent',
        'POST /api/v1/account/care/c1/consent',
      ]);
    },
  );

  testWidgets(
    'care screen identifies primary and additional doctors and consent',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PatientCareScreen(
            initial: PatientCare([
              PatientCentre(
                id: 'c1',
                name: 'Telomy Bengaluru',
                consentActive: false,
                consentExpiresAt: DateTime.utc(2020, 1),
                doctors: [
                  CareDoctor(id: 'd1', name: 'Dr Primary', isPrimary: true),
                  CareDoctor(id: 'd2', name: 'Dr Additional'),
                ],
              ),
            ]),
          ),
        ),
      );
      expect(find.text('Primary doctor'), findsOneWidget);
      expect(find.text('Additional doctor'), findsOneWidget);
      expect(find.text('Allow centre clinical access'), findsOneWidget);
      expect(find.textContaining('Clinical access expired on'), findsOneWidget);
      expect(find.textContaining('renew for one year'), findsOneWidget);
      expect(find.text('Assign doctor'), findsNothing);
    },
  );

  testWidgets('active consent shows its expiry date without payment claims', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PatientCareScreen(
          initial: PatientCare([
            PatientCentre(
              id: 'c1',
              name: 'Telomy Bengaluru',
              consentActive: true,
              consentExpiresAt: DateTime.utc(2030, 1, 7),
              doctors: const [],
            ),
          ]),
        ),
      ),
    );

    expect(find.textContaining('Clinical access expires on'), findsOneWidget);
    expect(find.textContaining('7 Jan 2030'), findsOneWidget);
    expect(find.textContaining('revenue'), findsNothing);
  });
}
