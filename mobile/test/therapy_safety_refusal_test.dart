import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/therapies/widgets/safety_refusal_card.dart';

void main() {
  testWidgets('a safety refusal stays visible and cannot book', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SafetyRefusalCard(
      explanations: ['Heat therapy cannot proceed after alcohol use today.'],
    ))));
    expect(find.text('Left out for safety'), findsOneWidget);
    expect(find.textContaining('alcohol use today'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Booking unavailable')).onPressed, isNull);
  });
}
