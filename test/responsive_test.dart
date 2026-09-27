import 'package:telomy/features/journal/providers/wellness_provider.dart';
import 'package:telomy/features/journal/models/wellness_data.dart';
import 'wellness_test_support.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/app/app.dart';
import 'package:telomy/features/auth/providers/auth_provider.dart';
import 'package:telomy/features/settings/providers/theme_provider.dart';
import 'widget_test.dart' show MemoryTokens;

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(393, 852),
    const Size(1024, 768),
  ]) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('restored dashboard at $size in $mode', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final tokens = MemoryTokens()..access = 'telomy-demo-session';
        final container = ProviderContainer(
          overrides: [
            tokenStorageProvider.overrideWithValue(tokens),
            wellnessRepositoryProvider.overrideWithValue(
              MemoryWellnessRepository(const WellnessData(demo: true)),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.read(themeProvider.notifier).setMode(mode);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const TelomyApp(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.textContaining('Hi Alex'), findsOneWidget);
        expect(
          find.byType(size.width >= 760 ? NavigationRail : BottomAppBar),
          findsOneWidget,
        );
        await tester.tap(find.text('Trends').last);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Your rhythm'),
          350,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
