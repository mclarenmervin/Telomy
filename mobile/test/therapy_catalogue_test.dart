import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telomy/app/role_routes.dart';
import 'package:telomy/features/roles/models/app_role.dart';
import 'package:telomy/features/therapies/models/therapy_catalogue.dart';
import 'package:telomy/features/therapies/screens/therapy_catalogue_screen.dart';
import 'package:telomy/features/therapies/screens/therapy_detail_screen.dart';
import 'package:telomy/features/therapies/screens/therapy_hub_screen.dart';
import 'package:telomy/features/therapies/models/therapy_plan.dart';
import 'package:telomy/features/therapies/models/therapy_session.dart';

const sauna = TherapyCatalogueItem(
  id: 'cat-1',
  slug: 'sauna',
  name: 'Sauna',
  category: 'Heat',
  summary: 'A dry heat session.',
  intendedExperience: 'Warm, supervised rest.',
  contraindicationRuleIds: ['pregnancy', 'alcohol_today'],
  doseSchema: {},
);

void main() {
  testWidgets('catalogue renders useful content and indicative price wording', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: TherapyCatalogueScreen(
          initialItems: [sauna],
          initialOfferings: [
            TherapyOffering(
              id: 'offer-1',
              centreId: 'c1',
              catalogueId: 'cat-1',
              indicativePriceMinor: 150000,
              currencyCode: 'INR',
            ),
          ],
        ),
      ),
    );
    expect(find.text('Sauna'), findsOneWidget);
    expect(find.textContaining('Indicative INR'), findsOneWidget);
    expect(find.text('A dry heat session.'), findsOneWidget);
  });

  testWidgets('detail names safety facts before booking', (tester) async {
    var proposed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: TherapyDetailScreen(
          item: sauna,
          onPropose: () async => proposed = true,
        ),
      ),
    );
    expect(find.text('Safety comes first'), findsOneWidget);
    expect(find.textContaining('Alcohol today'), findsOneWidget);
    await tester.tap(
      find.widgetWithText(FilledButton, 'Add to a proposed plan'),
    );
    await tester.pumpAndSettle();
    expect(proposed, isTrue);
  });

  test('therapy catalogue routes belong only to the patient shell', () {
    expect(routeRole('/therapies'), AppRole.member);
    expect(redirectFor(AppRole.doctor, '/therapies'), '/doctor');
  });

  testWidgets('patient therapy hub makes catalogue plans and sessions reachable', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: TherapyHubScreen(
      showEffects: false,
      initialPlans: [TherapyPlan(
        id: 'plan-1', patientId: 'u1', centreId: 'c1', version: 1,
        status: 'signed', contentSha256: 'abc', items: [],
      )],
      initialSessions: [TherapySession(
        id: 'session-1', status: 'scheduled',
        prescribedDose: {'duration_minutes': 20},
      )],
    ))));

    expect(find.text('Explore therapies'), findsOneWidget);
    expect(find.text('Plan v1'), findsOneWidget);
    expect(find.text('Scheduled session'), findsOneWidget);
  });
}
