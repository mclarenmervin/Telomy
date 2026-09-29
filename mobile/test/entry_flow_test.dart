import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/auth/providers/auth_provider.dart';
import 'package:telomy/features/journal/providers/wellness_provider.dart';
import 'package:telomy/features/journal/models/journal_entry.dart';
import 'package:telomy/features/journal/screens/journal_screen.dart';
import 'widget_test.dart' show MemoryTokens;
import 'wellness_test_support.dart';

void main() {
  testWidgets('a entered meal persists and is visible in history', (
    tester,
  ) async {
    final repo = MemoryWellnessRepository();
    final c = ProviderContainer(
      overrides: [
        tokenStorageProvider.overrideWithValue(
          MemoryTokens()..access = 'telomy-demo-session',
        ),
        wellnessRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: Scaffold(body: JournalScreen(kind: EntryKind.meal)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add record'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Title'),
      'Lunch',
    );
    await tester.scrollUntilVisible(
      find.widgetWithText(TextFormField, 'Energy (kcal)'),
      200,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Energy (kcal)'),
      '500',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Save record'),
      300,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.ensureVisible(find.text('Save record'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save record'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not save this change. Please retry.'),
      findsNothing,
    );
    expect(
      repo.data.entries.length,
      1,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .join(' | '),
    );
    expect(repo.data.entries.single.title, 'Lunch');
    expect(repo.data.entries.single.number('calories'), 500);
    expect(find.text('Lunch'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
