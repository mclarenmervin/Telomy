import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/centre/models/centre_operations.dart';
import 'package:telomy/features/centre/models/centre_roster.dart';
import 'package:telomy/features/centre/screens/doctors_screen.dart';
import 'package:telomy/features/centre/screens/patients_screen.dart';

void main() {
  testWidgets('members view shows only supplied consent-scoped members', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PatientsScreen(
          initial: [member()],
          doctors: const [
            CentrePerson(id: 'd1', name: 'Dr Meera', status: 'active'),
          ],
          onAssign: (_, _, _) async {},
        ),
      ),
    );

    expect(find.text('Asha'), findsOneWidget);
    expect(find.text('Never Consented'), findsNothing);
    expect(find.textContaining('asha@example.com'), findsNothing);
    expect(find.textContaining('98765'), findsNothing);
    expect(find.textContaining('Last visit'), findsOneWidget);
    expect(find.textContaining('Next booking'), findsOneWidget);
    expect(find.textContaining('Dr Meera'), findsOneWidget);
  });

  testWidgets('follow-up wording is safe and assignment remains available', (
    tester,
  ) async {
    var assigned = false;
    await tester.pumpWidget(
      MaterialApp(
        home: PatientsScreen(
          initial: [member()],
          doctors: const [
            CentrePerson(id: 'd1', name: 'Dr Meera', status: 'active'),
          ],
          onAssign: (_, _, _) async => assigned = true,
        ),
      ),
    );

    expect(
      find.text('Suggest a doctor consultation or retest.'),
      findsOneWidget,
    );
    expect(find.textContaining('diagnos'), findsNothing);
    await tester.tap(find.text('Assign doctor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dr Meera').last);
    await tester.tap(find.text('Save assignment'));
    await tester.pumpAndSettle();
    expect(assigned, isTrue);
  });

  testWidgets('doctor roster keeps invitation separate from member consent', (
    tester,
  ) async {
    var invited = '';
    await tester.pumpWidget(
      MaterialApp(
        home: DoctorsScreen(
          initial: const [
            CentrePerson(id: 'd1', name: 'Dr Meera', status: 'active'),
          ],
          onInvite: (email) async => invited = email,
        ),
      ),
    );

    expect(find.text('Team roster'), findsOneWidget);
    expect(find.textContaining('consent'), findsOneWidget);
    await tester.tap(find.text('Invite doctor'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Email'),
      'doctor@example.com',
    );
    await tester.tap(find.text('Send invitation'));
    await tester.pumpAndSettle();
    expect(invited, 'doctor@example.com');
  });
}

CentreMember member() => CentreMember.fromJson({
  'id': 'p1',
  'display_name': 'Asha',
  'assignments': [
    {'id': 'a1', 'doctor_id': 'd1', 'is_primary': true},
  ],
  'bookings': [
    {
      'id': 'past',
      'patient_id': 'p1',
      'service_id': 's1',
      'room_id': 'r1',
      'scheduled_start': '2026-09-01T09:00:00Z',
      'scheduled_end': '2026-09-01T09:30:00Z',
      'status': 'completed',
      'version': 1,
      'service_name_snapshot': 'Review',
      'duration_minutes_snapshot': 30,
      'indicative_price_minor_snapshot': 100000,
      'currency_code_snapshot': 'INR',
    },
    {
      'id': 'next',
      'patient_id': 'p1',
      'service_id': 's1',
      'room_id': 'r1',
      'scheduled_start': '2099-10-20T09:00:00Z',
      'scheduled_end': '2099-10-20T09:30:00Z',
      'status': 'booked',
      'version': 0,
      'service_name_snapshot': 'Review',
      'duration_minutes_snapshot': 30,
      'indicative_price_minor_snapshot': 100000,
      'currency_code_snapshot': 'INR',
    },
  ],
  'risk_evidence': [
    {
      'evidence_class': 'marker_trend',
      'date': '2026-10-01',
      'action': 'Suggest a doctor consultation or retest.',
    },
  ],
});
