import 'package:telomy/features/journal/providers/wellness_provider.dart';
import 'package:telomy/features/journal/models/wellness_data.dart';
import 'wellness_test_support.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telomy/app/app.dart';
import 'package:telomy/core/auth/token_storage.dart';
import 'package:telomy/features/auth/providers/auth_provider.dart';

class MemoryTokens implements TokenStorage {
  String? access;
  @override
  Future<String?> readAccessToken() async => access;
  @override
  Future<String?> readRefreshToken() async => null;
  @override
  Future<void> save({required String accessToken, String? refreshToken}) async {
    access = accessToken;
  }

  @override
  Future<void> clear() async {
    access = null;
  }
}

void main() {
  testWidgets('onboarding, validation, demo login, navigation, and logout', (
    tester,
  ) async {
    final tokens = MemoryTokens();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStorageProvider.overrideWithValue(tokens),
          wellnessRepositoryProvider.overrideWithValue(
            MemoryWellnessRepository(const WellnessData(demo: true)),
          ),
        ],
        child: const TelomyApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Get started'), 250);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid email address'), findsOneWidget);
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'alex@example.com',
    );
    await tester.enterText(find.byType(TextFormField).at(1), 'demo12345');
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsWidgets);
    await tester.tap(find.byTooltip('Log something'));
    await tester.pumpAndSettle();
    expect(find.text('Meal & nutrition'), findsOneWidget);
    await tester.tap(find.text('Meal & nutrition'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.timeline_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Trends'), findsWidgets);
    await tester.tap(find.byIcon(Icons.person_outline_rounded));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Sign out'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('TELOMY'), findsOneWidget);
    expect(tokens.access, isNull);
    expect(tester.takeException(), isNull);
  });
}
