import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/accounts/data/account_repository.dart';
import 'package:telomy/features/accounts/models/account_invitation.dart';
import 'package:telomy/features/accounts/providers/account_provider.dart';
import 'package:telomy/features/accounts/screens/pending_invitation_screen.dart';
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

Dio dio(ResponseBody Function(RequestOptions) handler) {
  final client = Dio(BaseOptions(baseUrl: 'http://localhost'));
  client.httpClientAdapter = StubAdapter(handler);
  return client;
}

ResponseBody jsonResponse(Object body, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

void main() {
  test('all four role labels are the approved product names', () {
    expect(AppRole.admin.label, 'Super Admin');
    expect(AppRole.centre.label, 'Centre Owner');
    expect(AppRole.doctor.label, 'Doctor');
    expect(AppRole.member.label, 'Patient');
  });

  test('repository parses pending and sends path-scoped decisions', () async {
    final paths = <String>[];
    final repository = AccountRepository(
      http: dio((options) {
        paths.add('${options.method} ${options.path}');
        if (options.method == 'GET') {
          return jsonResponse([
            {
              'invitation_id': 'i1',
              'email': 'patient@example.com',
              'intended_role': 'doctor',
              'centre_id': 'c1',
              'status': 'pending',
              'requires_verification': true,
              'expires_at': '2026-10-13T00:00:00Z',
            },
          ]);
        }
        return jsonResponse({
          'invitation_id': 'i1',
          'email': 'patient@example.com',
          'intended_role': 'doctor',
          'centre_id': 'c1',
          'status': options.path.endsWith('accept') ? 'accepted' : 'declined',
        });
      }),
    );
    final pending = await repository.pending();
    expect(pending.single.role, AppRole.doctor);
    expect(pending.single.requiresVerification, isTrue);
    await repository.accept('i1');
    await repository.decline('i1');
    expect(paths, [
      'GET /api/v1/invitations/pending',
      'POST /api/v1/invitations/i1/accept',
      'POST /api/v1/invitations/i1/decline',
    ]);
  });

  test('repository maps server failures without exposing internals', () async {
    final repository = AccountRepository(
      http: dio(
        (_) => jsonResponse({
          'detail': 'postgres secret stack trace',
        }, status: 500),
      ),
    );
    await expectLater(
      repository.pending(),
      throwsA(
        isA<AccountUnavailable>().having(
          (e) => e.message,
          'message',
          isNot(contains('postgres')),
        ),
      ),
    );
  });

  testWidgets(
    'pending, expired and revoked invitations render explicit states',
    (tester) async {
      final invitations = [
        AccountInvitation(
          id: 'i1',
          email: 'a@b.com',
          role: AppRole.doctor,
          centreId: 'c1',
          status: InvitationStatus.pending,
          expiresAt: DateTime(2030),
        ),
        AccountInvitation(
          id: 'i2',
          email: 'a@b.com',
          role: AppRole.member,
          centreId: 'c1',
          status: InvitationStatus.expired,
        ),
        AccountInvitation(
          id: 'i3',
          email: 'a@b.com',
          role: AppRole.centre,
          centreId: 'c1',
          status: InvitationStatus.revoked,
        ),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pendingInvitationsProvider.overrideWith((_) async => invitations),
          ],
          child: const MaterialApp(home: PendingInvitationScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Doctor'), findsOneWidget);
      expect(find.text('Expired'), findsOneWidget);
      expect(find.text('Revoked'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
    },
  );
}
