import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/centre/models/centre_operations.dart';
import 'package:telomy/features/centre/screens/room_editor_screen.dart';
import 'package:telomy/features/centre/screens/service_editor_screen.dart';
import 'package:telomy/features/centre/screens/services_screen.dart';
import 'package:telomy/features/centre/widgets/booking_card.dart';

void main() {
  testWidgets('services show duration indicative price and compatible rooms', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ServicesScreen(
          initialServices: services,
          initialRooms: rooms,
          onRetire: (_) async {},
        ),
      ),
    );
    expect(find.text('Review'), findsOneWidget);
    expect(find.textContaining('30 min'), findsOneWidget);
    expect(find.textContaining('indicative'), findsWidgets);
    expect(find.textContaining('Room A'), findsWidgets);
    expect(find.text('Retire'), findsOneWidget);
  });

  testWidgets('service editor validates operational values', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ServiceEditorScreen(onCreate: (_) async {})),
    );
    final create = find.widgetWithText(FilledButton, 'Create service');
    expect(tester.widget<FilledButton>(create).onPressed, isNull);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Review');
    await tester.enterText(
      find.widgetWithText(TextField, 'Duration (minutes)'),
      '30',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Indicative price'),
      '1250',
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(create).onPressed, isNotNull);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Centre currency'))
          .readOnly,
      isTrue,
    );
  });

  testWidgets('room editor rejects invalid weekly hours', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: RoomEditorScreen(onCreate: (_) async {})),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Room name'),
      'Room A',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Opens (HH:mm)'),
      '17:00',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Closes (HH:mm)'),
      '09:00',
    );
    await tester.pump();
    expect(find.textContaining('after opening'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Create room'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('historical booking keeps its immutable service snapshot', (
    tester,
  ) async {
    final booking = CentreBooking.fromJson({
      'id': 'b1',
      'patient_id': 'p1',
      'service_id': 's1',
      'room_id': 'r1',
      'scheduled_start': '2026-10-14T09:00:00Z',
      'scheduled_end': '2026-10-14T09:30:00Z',
      'status': 'completed',
      'version': 1,
      'service_name_snapshot': 'Original review',
      'duration_minutes_snapshot': 30,
      'indicative_price_minor_snapshot': 125000,
      'currency_code_snapshot': 'INR',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookingCard(booking: booking, onCommand: (_, _, _) async {}),
        ),
      ),
    );
    expect(find.text('Original review'), findsOneWidget);
    expect(find.text('Renamed service'), findsNothing);
  });

  testWidgets('active compatibility and hours expose maintenance actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ServicesScreen(
          initialServices: services,
          initialRooms: rooms,
          onUnlink: (_, _) async {},
          onEndHours: (_, _) async {},
        ),
      ),
    );
    expect(find.text('Unlink room'), findsOneWidget);
    expect(find.text('End hours'), findsOneWidget);
  });
}

const rooms = CentreRooms(
  items: [CentreRoom(id: 'r1', name: 'Room A', status: 'active')],
  hours: [
    CentreRoomHours(
      id: 'h1',
      roomId: 'r1',
      weekday: 1,
      opensAt: '09:00',
      closesAt: '17:00',
      validFrom: '2026-10-01',
    ),
  ],
);
const services = CentreServices(
  items: [
    CentreService(
      id: 's1',
      name: 'Review',
      durationMinutes: 30,
      indicativePriceMinor: 125000,
      currencyCode: 'INR',
      status: 'active',
    ),
  ],
  compatibility: [RoomServiceLink(id: 'l1', roomId: 'r1', serviceId: 's1')],
);
