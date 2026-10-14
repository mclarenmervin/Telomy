import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/centre/models/centre_operations.dart';
import 'package:telomy/features/centre/screens/centre_dashboard_screen.dart';

void main() {
  testWidgets(
    'dashboard names every metric and keeps financial wording honest',
    (tester) async {
      await pumpDashboard(tester, const Size(393, 852), sampleDashboard());
      for (final text in [
        'Indicative booking value',
        'Sessions',
        'Members',
        'Active in 30 days',
        'No-shows',
        "Today's bookings",
        'Service utilisation',
        'Follow-up recommended',
        'Not seen in 30 days',
      ]) {
        expect(find.text(text), findsWidgets);
      }
      expect(find.textContaining('not payment revenue'), findsOneWidget);
      expect(find.textContaining('configured room capacity'), findsOneWidget);
      expect(find.textContaining('F12'), findsOneWidget);
      expect(find.textContaining('F13'), findsOneWidget);
      expect(find.byKey(const Key('centre-dashboard-phone')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tablet dashboard uses two operational columns without overflow',
    (tester) async {
      await pumpDashboard(tester, const Size(1024, 768), sampleDashboard());
      expect(find.byKey(const Key('centre-dashboard-tablet')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dashboard has directed loading, error, and empty states', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: CentreDashboardScreen(state: AsyncLoading())),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: CentreDashboardScreen(
              state: AsyncError(Exception('offline'), StackTrace.empty),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('Try again'), findsOneWidget);
    await pumpDashboard(
      tester,
      const Size(393, 852),
      sampleDashboard(empty: true),
    );
    expect(find.text('No bookings today'), findsOneWidget);
    expect(find.text('No members currently need follow-up'), findsOneWidget);
  });
}

Future<void> pumpDashboard(
  WidgetTester tester,
  Size size,
  CentreDashboard value,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: CentreDashboardScreen(state: AsyncData(value))),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

CentreDashboard sampleDashboard({bool empty = false}) =>
    CentreDashboard.fromJson({
      'centre': {
        'id': 'c1',
        'name': 'North Centre',
        'timezone_name': 'Asia/Kolkata',
        'currency_code': 'INR',
      },
      'indicative_booking_value': {
        'currency_code': 'INR',
        'current_month_minor': 125000,
        'previous_month_minor': 80000,
      },
      'sessions': {'current_month': 3, 'previous_month': 2},
      'members': {
        'total': 2,
        'active_30_days': ['p1'],
        'not_seen_30_days': ['p2'],
      },
      'today_bookings': empty
          ? []
          : [
              {
                'id': 'b1',
                'patient_id': 'p1',
                'service_id': 's1',
                'room_id': 'r1',
                'scheduled_start': '2026-10-14T09:00:00Z',
                'scheduled_end': '2026-10-14T09:30:00Z',
                'status': 'booked',
                'version': 0,
                'service_name_snapshot': 'Review',
                'duration_minutes_snapshot': 30,
                'indicative_price_minor_snapshot': 125000,
                'currency_code_snapshot': 'INR',
              },
            ],
      'no_show': {'numerator': 1, 'denominator': 4, 'rate': .25},
      'utilisation': empty
          ? []
          : [
              {
                'service_id': 's1',
                'service_name': 'Review',
                'capacity_minutes': 240,
                'utilised_minutes': 120,
                'rate': .5,
                'inconsistent_over_capacity': false,
              },
            ],
      'members_at_risk': empty
          ? []
          : [
              {
                'id': 'p1',
                'display_name': 'Asha',
                'evidence_class': 'attention_reading',
                'date': '2026-10-13',
                'action': 'Suggest a doctor consultation or retest.',
              },
            ],
    });
