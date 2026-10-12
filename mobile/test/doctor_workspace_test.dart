import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/doctor/models/doctor_models.dart';
import 'package:telomy/features/doctor/screens/doctor_today_screen.dart';
import 'package:telomy/features/doctor/screens/doctor_patients_screen.dart';
import 'package:telomy/features/doctor/widgets/centre_selector.dart';
import 'package:telomy/features/doctor/screens/doctor_work_queue_screen.dart';
import 'package:telomy/features/doctor/widgets/clinical_decision_sheet.dart';

void main() {
  testWidgets(
    'centre selector and Today keep critical escalation separate from queue',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                CentreSelector(
                  centres: const [
                    DoctorCentre(id: 'a', name: 'A'),
                    DoctorCentre(id: 'b', name: 'B'),
                  ],
                  selectedId: 'a',
                  onSelected: (_) {},
                ),
                Expanded(
                  child: DoctorTodayScreen(
                    initial: const DoctorToday(
                      patientCount: 3,
                      pendingWork: 2,
                      criticalEscalations: [
                        {'id': 'e1'},
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('A'), findsOneWidget);
      expect(find.text('Critical escalations'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2 items awaiting review'), findsOneWidget);
    },
  );
  testWidgets('patients screen renders assigned patients only', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: DoctorPatientsScreen(
          initial: [DoctorPatient(id: 'p1', name: 'Assigned Patient')],
        ),
      ),
    );
    expect(find.text('Assigned Patient'), findsOneWidget);
    expect(find.text('No patients assigned'), findsNothing);
  });
  testWidgets('work queue shows all five segments', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: DoctorWorkQueueScreen(
          initial: DoctorWorkQueue({
            'monthly_reports': [],
            'sync_drafts': [],
            'consults': [],
            'therapy_plans': [],
            'rx_supplements': [],
          }),
        ),
      ),
    );
    for (final label in [
      'Monthly reports',
      'Sinc drafts',
      'Consults',
      'Therapy plans',
      'Rx & supplements',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
  });
  testWidgets('decision actions require a nonblank note', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClinicalDecisionSheet(
            onSign: (_) async {},
            onReject: (_) async {},
          ),
        ),
      ),
    );
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Sign'))
          .onPressed,
      isNull,
    );
    await t.enterText(find.byType(TextField), 'Reviewed');
    await t.pump();
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Sign'))
          .onPressed,
      isNotNull,
    );
  });
}
