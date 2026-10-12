import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/app/app.dart';
import 'package:telomy/app/router.dart';
import 'package:telomy/features/auth/providers/auth_provider.dart';
import 'package:telomy/features/journal/models/wellness_data.dart';
import 'package:telomy/features/journal/providers/wellness_provider.dart';
import 'package:telomy/features/roles/data/role_repository.dart';
import 'package:telomy/features/roles/models/app_role.dart';
import 'package:telomy/features/roles/providers/role_provider.dart';

import 'wellness_test_support.dart';
import 'widget_test.dart' show MemoryTokens;

/// One shell, four roles, verified by signing in as each of them.
///
/// The phase asks for the role spine to be checked as all four roles rather
/// than reasoned about, and this is that check on the phone. The database
/// half is `db/tests/app_role_test.sql`, which authenticates as each role and
/// asserts zero rows; the gateway half is `tests/test_app_role.py`. This one
/// is about what a person sees.
///
/// Signing in is driven through the real demo login rather than by overriding
/// the auth state, because the thing being tested is the redirect — and a
/// redirect given a hand-made session is a redirect running in conditions it
/// never meets.
Future<void> signIn(WidgetTester tester, AppRole role) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tokenStorageProvider.overrideWithValue(MemoryTokens()),
        wellnessRepositoryProvider.overrideWithValue(
          MemoryWellnessRepository(const WellnessData(demo: true)),
        ),
        roleRepositoryProvider.overrideWithValue(FixedRoleRepository(role)),
      ],
      child: const TelomyApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text('Get started'), 250);
  await tester.tap(find.text('Get started'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField).at(0), 'alex@example.com');
  await tester.enterText(find.byType(TextFormField).at(1), 'demo12345');
  await tester.ensureVisible(find.text('Sign in'));
  await tester.tap(find.text('Sign in'));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

/// Already signed in, without driving the login flow.
///
/// The flow itself is what `signIn` tests. At tablet width the onboarding
/// layout differs enough that driving it is testing the onboarding screen
/// rather than the shell, which is what `responsive_test` already does by
/// pre-seeding the session — the same trick here.
Future<void> alreadySignedIn(WidgetTester tester, AppRole role) async {
  final tokens = MemoryTokens()..access = 'telomy-demo-session';
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tokenStorageProvider.overrideWithValue(tokens),
        wellnessRepositoryProvider.overrideWithValue(
          MemoryWellnessRepository(const WellnessData(demo: true)),
        ),
        roleRepositoryProvider.overrideWithValue(FixedRoleRepository(role)),
      ],
      child: const TelomyApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  test('role labels match the four account types', () {
    expect(AppRole.admin.label, 'Super Admin');
    expect(AppRole.centre.label, 'Centre Owner');
    expect(AppRole.doctor.label, 'Doctor');
    expect(AppRole.member.label, 'Patient');
  });

  testWidgets('a member lands in the member app with a log button', (
    tester,
  ) async {
    await signIn(tester, AppRole.member);

    expect(find.text('Today'), findsWidgets);
    expect(find.text('Trends'), findsWidgets);
    expect(find.byTooltip('Log something'), findsOneWidget);
  });

  testWidgets('an admin lands on platform health, and does not log meals', (
    tester,
  ) async {
    await signIn(tester, AppRole.admin);

    expect(find.text('Health'), findsWidgets);
    expect(find.text('Catalogue'), findsWidgets);
    expect(find.text('Audit'), findsWidgets);
    // A doctor does not log a meal, and neither do we. The shell takes the
    // role, which is the whole reason it was not forked.
    expect(find.byTooltip('Log something'), findsNothing);
    // And none of the member's tabs are anywhere on screen.
    expect(find.text('Sinc'), findsNothing);
  });

  testWidgets('a doctor lands on their own shell with F10 named', (
    tester,
  ) async {
    await signIn(tester, AppRole.doctor);

    expect(find.text('Work'), findsWidgets);
    expect(find.text('Patients'), findsWidgets);
    expect(find.byTooltip('Log something'), findsNothing);
    // Not a stub. It says which phase, what will be here, and what is
    // already built underneath — because a blank screen reads as a broken
    // product to whoever signs in next.
    expect(find.textContaining('F10 builds this'), findsOneWidget);
  });

  testWidgets('a centre operator lands on their own shell', (tester) async {
    await signIn(tester, AppRole.centre);

    expect(find.text('Floor'), findsWidgets);
    expect(find.text('Bookings'), findsWidgets);
    expect(find.byTooltip('Log something'), findsNothing);
  });

  testWidgets('a member who deep-links to an admin route is sent home', (
    tester,
  ) async {
    await signIn(tester, AppRole.member);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Navigator).first),
    );

    container.read(routerProvider).go('/admin/catalogue');
    await tester.pumpAndSettle();

    expect(
      container.read(routerProvider).state.uri.path,
      '/home',
      reason: 'the router refuses it; the gateway and RLS refuse it again',
    );
    expect(find.text('Catalogue'), findsNothing);
  });

  testWidgets('an admin who deep-links to a doctor route is sent back', (
    tester,
  ) async {
    // An admin is not a superuser of the other roles' screens. Treating them
    // as one is how a support tool becomes the God account.
    await signIn(tester, AppRole.admin);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Navigator).first),
    );

    container.read(routerProvider).go('/doctor/patients');
    await tester.pumpAndSettle();

    expect(container.read(routerProvider).state.uri.path, '/admin');
  });

  testWidgets('the rail replaces the bar at 760 px for every role', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await alreadySignedIn(tester, AppRole.admin);

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(BottomAppBar), findsNothing);
  });
}
