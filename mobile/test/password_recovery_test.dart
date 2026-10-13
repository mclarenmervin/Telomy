import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:telomy/app/app.dart';
import 'package:telomy/app/router.dart';
import 'package:telomy/features/auth/data/auth_repository.dart';
import 'package:telomy/features/auth/data/supabase_auth_repository.dart';
import 'package:telomy/features/auth/models/app_user.dart';
import 'package:telomy/features/auth/providers/auth_provider.dart';
import 'package:telomy/features/auth/screens/update_password_screen.dart';

class _RecordingClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode('{}')),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

class _FakeAuthRepository implements AuthRepository {
  String? updatedPassword;

  @override
  Future<AppUser?> restoreSession() async => null;
  @override
  Future<AppUser> login(String email, String password) =>
      throw UnimplementedError();
  @override
  Future<AppUser> signup({
    required String fullName,
    required String email,
    required String phone,
    required String password,
  }) => throw UnimplementedError();
  @override
  Future<void> forgotPassword(String email) => throw UnimplementedError();
  @override
  Future<void> updatePassword(String password) async {
    updatedPassword = password;
  }

  @override
  Future<void> deleteAccount() => throw UnimplementedError();
  @override
  Future<void> logout() async {}
}

void main() {
  test('password recovery requests the pre-login Telomy callback', () async {
    final httpClient = _RecordingClient();
    final client = SupabaseClient(
      'https://project.supabase.co',
      'publishable-key',
      httpClient: httpClient,
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
    );
    final repository = SupabaseAuthRepository(client);

    await repository.forgotPassword('person@example.com');

    expect(
      httpClient.requests.single.url.queryParameters['redirect_to'],
      'telomy://auth/reset-password',
    );
  });

  test('recovery session can set a new password and then signs out', () async {
    final httpClient = _RecordingClient();
    final client = SupabaseClient(
      'https://project.supabase.co',
      'publishable-key',
      httpClient: httpClient,
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
    );
    await client.auth.recoverSession(
      jsonEncode({
        'access_token': 'header.payload.signature',
        'refresh_token': 'refresh-token',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': {'id': '00000000-0000-4000-8000-000000000123'},
      }),
    );
    final dynamic repository = SupabaseAuthRepository(client);

    await repository.updatePassword('StrongerPassword123!');

    final update = httpClient.requests.firstWhere(
      (request) =>
          request.method == 'PUT' && request.url.path.endsWith('/user'),
    );
    expect(
      jsonDecode((update as http.Request).body),
      containsPair('password', 'StrongerPassword123!'),
    );
    expect(client.auth.currentSession, isNull);
  });

  testWidgets('recovery link sets a new password before returning to sign in', (
    tester,
  ) async {
    final repository = _FakeAuthRepository();
    final router = GoRouter(
      initialLocation: '/reset-password',
      routes: [
        GoRoute(
          path: '/reset-password',
          builder: (_, _) => const UpdatePasswordScreen(),
        ),
        GoRoute(
          path: '/login',
          builder: (_, _) => const Scaffold(body: Text('Sign in destination')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'New password'),
      'StrongerPassword123!',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Confirm new password'),
      'StrongerPassword123!',
    );
    await tester.tap(find.text('Set new password'));
    await tester.pumpAndSettle();

    expect(repository.updatedPassword, 'StrongerPassword123!');
    expect(find.text('Sign in destination'), findsOneWidget);
  });

  testWidgets('an unauthenticated recovery deep link stays on its form', (
    tester,
  ) async {
    final repository = _FakeAuthRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(repository)],
        child: const TelomyApp(),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Navigator).first),
    );

    container.read(routerProvider).go('/reset-password');
    await tester.pumpAndSettle();

    expect(container.read(routerProvider).state.uri.path, '/reset-password');
    expect(find.byType(UpdatePasswordScreen), findsOneWidget);
  });
}
