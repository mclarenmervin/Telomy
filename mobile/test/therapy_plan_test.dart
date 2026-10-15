import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/therapies/models/therapy_plan.dart';
import 'package:telomy/features/therapies/screens/therapy_plan_screen.dart';

const plan = TherapyPlan(
  id: 'p1', patientId: 'u1', centreId: 'c1', version: 1,
  status: 'proposed', contentSha256: 'abc',
  items: [
    TherapyPlanItem(id: 'i1', catalogueId: 'sauna', name: 'Sauna', disposition: 'proposed', prescribedDose: {'duration_minutes': 20}, frequency: {}),
    TherapyPlanItem(id: 'i2', catalogueId: 'hbot', name: 'HBOT', disposition: 'excluded_safety', prescribedDose: {'duration_minutes': 60}, frequency: {}, safetyExplanation: 'Cannot proceed with an untreated pneumothorax.'),
  ],
);

void main() {
  testWidgets('patient sees proposed and safety-excluded plan items', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TherapyPlanScreen(plan: plan, viewer: TherapyPlanViewer.patient)));
    expect(find.text('In this plan'), findsOneWidget);
    expect(find.text('Left out for safety'), findsOneWidget);
    expect(find.textContaining('pneumothorax'), findsOneWidget);
    expect(find.text('Awaiting doctor review'), findsOneWidget);
  });

  testWidgets('doctor can sign while centre owner has no clinical editing control', (tester) async {
    await tester.pumpWidget(MaterialApp(home: TherapyPlanScreen(plan: plan, viewer: TherapyPlanViewer.doctor, onSign: (_) async {})));
    expect(find.widgetWithText(FilledButton, 'Review and sign'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: TherapyPlanScreen(plan: plan, viewer: TherapyPlanViewer.centre)));
    expect(find.widgetWithText(FilledButton, 'Review and sign'), findsNothing);
    expect(find.text('Operational view only'), findsOneWidget);
  });
}
