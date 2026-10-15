import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/therapies/models/therapy_session.dart';
import 'package:telomy/features/therapies/screens/therapy_session_screen.dart';
import 'package:telomy/features/therapies/widgets/therapy_checkin_sheet.dart';

void main() {
  testWidgets('session shows lifecycle and keeps prescribed and delivered doses distinct', (tester) async {
    const session = TherapySession(id: 's1', status: 'completed', prescribedDose: {'duration_minutes': 20}, deliveredDose: {'duration_minutes': 17});
    await tester.pumpWidget(const MaterialApp(home: TherapySessionScreen(session: session)));
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('Prescribed: 20 minutes'), findsOneWidget);
    expect(find.text('Delivered: 17 minutes'), findsOneWidget);
  });

  testWidgets('check-in presents no more than two questions', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TherapyCheckinSheet(
      questions: const [
        TherapyCheckinQuestion(code: 'felt', prompt: 'How did it feel?'),
        TherapyCheckinQuestion(code: 'repeat', prompt: 'Would you repeat it?'),
        TherapyCheckinQuestion(code: 'extra', prompt: 'This must not appear'),
      ], onSubmit: (_) async {},
    ))));
    expect(find.text('How did it feel?'), findsOneWidget);
    expect(find.text('Would you repeat it?'), findsOneWidget);
    expect(find.text('This must not appear'), findsNothing);
  });
}
