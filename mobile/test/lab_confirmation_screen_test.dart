import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/labs/data/lab_confirmation.dart';
import 'package:telomy/features/labs/screens/lab_confirmation_screen.dart';

import 'lab_confirmation_test.dart' show result, upload;

/// What the screen is and is not allowed to say.
///
/// The notice about unreviewed ranges is not decoration. Showing numbers with
/// no interpretation and no explanation would leave the user guessing, and
/// showing an interpretation would be a claim no clinician has agreed to.

Future<ConfirmationDraft?> pump(
  WidgetTester tester, {
  bool named = true,
  String collectedAtSource = 'extracted',
}) async {
  ConfirmationDraft? submitted;
  await tester.pumpWidget(
    MaterialApp(
      home: LabConfirmationScreen(
        upload: upload(
          patientName: named ? 'MRS SUNITA R PATNAIK' : null,
          collectedAtSource: collectedAtSource,
        ),
        results: [
          result('r1', rawValue: '7.8'),
          result('r2', biomarkerId: 'vitamin_d_25oh', operator: '<', rawValue: '3.0'),
        ],
        onSubmit: (draft) async => submitted = draft,
      ),
    ),
  );
  return submitted;
}

final submitButton = find.byKey(const Key('lab-confirm-submit'));

/// The screen is a ListView, so the button at the bottom is genuinely not built
/// until it is scrolled to — exactly as a user reaches it.
Future<FilledButton> submit(WidgetTester tester) async {
  await tester.scrollUntilVisible(submitButton, 300);
  return tester.widget<FilledButton>(submitButton);
}

void main() {
  testWidgets('it says the ranges are not reviewed yet', (tester) async {
    await pump(tester);

    expect(find.textContaining('still being'), findsOneWidget);
  });

  testWidgets('it shows no verdict for any value', (tester) async {
    await pump(tester);

    for (final word in ['Normal', 'High', 'Low', 'Optimal', 'Abnormal']) {
      expect(find.text(word), findsNothing, reason: '$word is a claim we cannot make');
    }
  });

  testWidgets('it shows the value exactly as the report printed it', (tester) async {
    await pump(tester);

    expect(find.textContaining('7.8'), findsWidgets);
    expect(find.textContaining('<3.0'), findsWidgets);
  });

  testWidgets('it says where each value came from', (tester) async {
    await pump(tester);

    expect(find.textContaining('from page 1'), findsWidgets);
  });

  testWidgets('a censored value is explained rather than quietly dropped',
      (tester) async {
    await pump(tester);

    expect(find.textContaining('not use it in calculations'), findsOneWidget);
  });

  testWidgets('submit is disabled until everything is decided', (tester) async {
    await pump(tester);

    expect((await submit(tester)).onPressed, isNull);
  });

  testWidgets('it asks whose report it is when a name was read', (tester) async {
    await pump(tester);

    expect(find.text('Is this your report?'), findsOneWidget);
    expect(find.textContaining('SUNITA'), findsWidgets);
  });

  testWidgets('it does not ask when no name was read', (tester) async {
    await pump(tester, named: false);

    expect(find.text('Is this your report?'), findsNothing);
  });

  testWidgets('it asks for the collection date when we could not read one',
      (tester) async {
    await pump(tester, collectedAtSource: 'unknown');

    expect(find.text('When was the sample taken?'), findsOneWidget);
    expect(find.textContaining('could not read'), findsOneWidget);
  });

  testWidgets('it does not ask when the date was read confidently', (tester) async {
    await pump(tester);

    expect(find.text('When was the sample taken?'), findsNothing);
  });

  testWidgets('deciding everything enables submit and hands over the draft',
      (tester) async {
    // Tall enough that every chip is laid out: the chips of a second result
    // sit below the fold on a phone-sized surface, and a tap that misses is a
    // test passing for the wrong reason rather than a finding.
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    ConfirmationDraft? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: LabConfirmationScreen(
          upload: upload(patientName: null),
          results: [result('r1'), result('r2', biomarkerId: 'ferritin')],
          onSubmit: (draft) async => submitted = draft,
        ),
      ),
    );

    await tester.tap(find.text('Correct').first);
    await tester.pump();
    await tester.tap(find.text('Correct').last);
    await tester.pump();

    expect((await submit(tester)).onPressed, isNotNull);

    await tester.tap(submitButton);
    await tester.pumpAndSettle();

    expect(submitted, isNotNull);
    expect(submitted!.canSubmit, isTrue);
  });

  testWidgets('saying the report is someone else blocks submission',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pump(tester);

    await tester.tap(find.text('Correct').first);
    await tester.pump();
    await tester.tap(find.text('Correct').last);
    await tester.pump();
    await tester.tap(find.text('No, someone else'));
    await tester.pump();

    expect((await submit(tester)).onPressed, isNull);
    expect(find.textContaining('only add your own'), findsOneWidget);
  });
}
