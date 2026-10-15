import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/app/role_routes.dart';
import 'package:telomy/features/roles/models/app_role.dart';
import 'package:telomy/features/therapies/models/therapy_catalogue.dart';
import 'package:telomy/features/therapies/screens/therapy_catalogue_screen.dart';
import 'package:telomy/features/therapies/screens/therapy_detail_screen.dart';

const sauna = TherapyCatalogueItem(
  id: 'cat-1', slug: 'sauna', name: 'Sauna', category: 'Heat',
  summary: 'A dry heat session.', intendedExperience: 'Warm, supervised rest.',
  contraindicationRuleIds: ['pregnancy', 'alcohol_today'], doseSchema: {},
);

void main() {
  testWidgets('catalogue renders useful content and indicative price wording', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TherapyCatalogueScreen(
      initialItems: [sauna],
      initialOfferings: [TherapyOffering(id: 'offer-1', centreId: 'c1', catalogueId: 'cat-1', indicativePriceMinor: 150000, currencyCode: 'INR')],
    )));
    expect(find.text('Sauna'), findsOneWidget);
    expect(find.textContaining('Indicative INR'), findsOneWidget);
    expect(find.text('A dry heat session.'), findsOneWidget);
  });

  testWidgets('detail names safety facts before booking', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TherapyDetailScreen(item: sauna)));
    expect(find.text('Safety comes first'), findsOneWidget);
    expect(find.textContaining('Alcohol today'), findsOneWidget);
  });

  test('therapy catalogue routes belong only to the patient shell', () {
    expect(routeRole('/therapies'), AppRole.member);
    expect(redirectFor(AppRole.doctor, '/therapies'), '/doctor');
  });
}
