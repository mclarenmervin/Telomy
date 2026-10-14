import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/centre/data/centre_repository.dart';
import 'package:telomy/features/centre/models/centre_operations.dart';
import 'package:telomy/features/centre/screens/booking_editor_screen.dart';
import 'package:telomy/features/centre/screens/bookings_screen.dart';
import 'package:telomy/features/centre/widgets/booking_card.dart';

void main() {
  testWidgets('booking list offers date and status filters', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BookingsScreen(initial: [booking(status: 'booked')]),
      ),
    );
    expect(find.text('Date'), findsOneWidget);
    expect(find.text('All statuses'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);
  });

  testWidgets('date filter excludes bookings from other local days', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BookingsScreen(
          initial: [booking(status: 'booked')],
          initialDate: DateTime(2026, 10, 15),
        ),
      ),
    );
    expect(find.text('Review'), findsNothing);
    expect(find.text('No bookings match these filters.'), findsOneWidget);
  });

  testWidgets('booking editor validates required operational fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: BookingEditorScreen(onCreate: (_) async {})),
    );
    final button = find.widgetWithText(FilledButton, 'Create booking');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    for (final entry in {
      'Patient ID': 'p1',
      'Service ID': 's1',
      'Room ID': 'r1',
    }.entries) {
      await tester.enterText(
        find.widgetWithText(TextField, entry.key),
        entry.value,
      );
    }
    await tester.tap(find.text('Choose time'));
    await tester.pump();
    expect(find.textContaining('future'), findsWidgets);
  });

  testWidgets(
    'booking card exposes only legal commands and disables terminal rows',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BookingCard(
              booking: booking(status: 'booked'),
              now: DateTime.utc(2026, 10, 14, 10),
              onCommand: (_, _, _) async {},
            ),
          ),
        ),
      );
      expect(find.text('Check in'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Complete'), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BookingCard(
              booking: booking(status: 'completed'),
              now: DateTime.utc(2026, 10, 14, 10),
              onCommand: (_, _, _) async {},
            ),
          ),
        ),
      );
      expect(find.text('Booking complete'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    },
  );

  testWidgets('no-show command explains and obeys its grace period', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookingCard(
            booking: booking(status: 'booked'),
            now: DateTime.utc(2026, 10, 14, 9, 5),
            onCommand: (_, _, _) async {},
          ),
        ),
      ),
    );
    expect(find.textContaining('15-minute grace'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Mark no-show'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('stale transition refreshes and never infers local success', (
    tester,
  ) async {
    var refreshed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookingsScreen(
            initial: [booking(status: 'booked')],
            onRefresh: () async {
              refreshed++;
            },
            onTransition: (_, _, _) async => throw const CentreConflict(),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Check in'));
    await tester.pumpAndSettle();
    expect(refreshed, 1);
    expect(find.textContaining('changed'), findsOneWidget);
    expect(find.text('booked'), findsOneWidget);
  });

  testWidgets('create flow adds only the authoritative returned booking', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BookingsScreen(
          initial: const [],
          onCreate: (_) async => booking(status: 'booked'),
        ),
      ),
    );
    await tester.tap(find.text('Add booking'));
    await tester.pumpAndSettle();
    expect(find.text('Create booking'), findsWidgets);
  });

  testWidgets('checked-in cancellation requires and forwards a reason', (
    tester,
  ) async {
    String? received;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookingCard(
            booking: booking(status: 'checked_in'),
            onCommand: (_, _, reason) async => received = reason,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Cancellation reason'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '  Patient requested  ');
    await tester.tap(find.text('Cancel booking'));
    await tester.pumpAndSettle();
    expect(received, 'Patient requested');
  });

  testWidgets('date filter uses the centre timezone', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BookingsScreen(
          initial: [bookingAt('2026-10-14T20:00:00Z')],
          initialDate: DateTime(2026, 10, 15),
          timezoneName: 'Asia/Kolkata',
        ),
      ),
    );
    expect(find.text('Review'), findsOneWidget);
    expect(find.text('15/10/2026 · 01:30–02:00'), findsOneWidget);
  });

  testWidgets('booking card shows patient and room labels, never raw IDs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookingCard(
            booking: labelledBooking(),
            onCommand: (_, _, _) async {},
          ),
        ),
      ),
    );

    expect(
      find.text('Patient Acceptance Member · Room Consultation A'),
      findsOneWidget,
    );
    expect(find.textContaining('patient-uuid'), findsNothing);
    expect(find.textContaining('room-uuid'), findsNothing);
  });
}

CentreBooking booking({required String status}) => CentreBooking.fromJson({
  'id': 'b1',
  'patient_id': 'p1',
  'service_id': 's1',
  'room_id': 'r1',
  'scheduled_start': '2026-10-14T09:00:00Z',
  'scheduled_end': '2026-10-14T09:30:00Z',
  'status': status,
  'version': 2,
  'service_name_snapshot': 'Review',
  'duration_minutes_snapshot': 30,
  'indicative_price_minor_snapshot': 125000,
  'currency_code_snapshot': 'INR',
});

CentreBooking bookingAt(String start) => CentreBooking.fromJson({
  'id': 'b2',
  'patient_id': 'p1',
  'service_id': 's1',
  'room_id': 'r1',
  'scheduled_start': start,
  'scheduled_end': DateTime.parse(
    start,
  ).add(const Duration(minutes: 30)).toIso8601String(),
  'status': 'booked',
  'version': 1,
  'service_name_snapshot': 'Review',
  'duration_minutes_snapshot': 30,
  'indicative_price_minor_snapshot': 100,
  'currency_code_snapshot': 'INR',
});

CentreBooking labelledBooking() => CentreBooking.fromJson({
  'id': 'booking-uuid',
  'patient_id': 'patient-uuid',
  'patient_display_name': 'Acceptance Member',
  'service_id': 'service-uuid',
  'room_id': 'room-uuid',
  'room_name': 'Consultation A',
  'scheduled_start': '2026-10-14T09:00:00Z',
  'scheduled_end': '2026-10-14T09:30:00Z',
  'status': 'booked',
  'version': 0,
  'service_name_snapshot': 'Review',
  'duration_minutes_snapshot': 30,
  'indicative_price_minor_snapshot': 125000,
  'currency_code_snapshot': 'INR',
});
