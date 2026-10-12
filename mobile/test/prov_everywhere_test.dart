import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/app/theme/app_theme.dart';
import 'package:telomy/core/vocabulary/vocabulary.dart';
import 'package:telomy/features/correlations/models/correlation.dart';
import 'package:telomy/features/correlations/providers/correlation_provider.dart';
import 'package:telomy/features/correlations/screens/correlations_screen.dart';
import 'package:telomy/features/environment/data/coarse_places.dart';
import 'package:telomy/features/environment/models/environment_snapshot.dart';
import 'package:telomy/features/environment/providers/environment_provider.dart';
import 'package:telomy/features/environment/widgets/environment_section.dart';
import 'package:telomy/features/therapies/models/therapy_effect.dart';
import 'package:telomy/features/therapies/providers/therapy_provider.dart';
import 'package:telomy/features/therapies/widgets/therapy_effects_section.dart';

/// Bite 7: every number on every existing screen goes through [Prov].
///
/// This is the roadmap's F01 arriving on screens that already shipped, and it
/// is the only reason F9 touches them at all. After this phase, a number
/// rendered without a source, a time and a confidence is a review failure.
///
/// The handoff's correction matters here: this now covers four screens that
/// did not exist when bite 7 was written — the correlation cards, the therapy
/// effects, the environment day cards and the genetics variant list. Each had
/// already grown its own provenance sentence by hand, and those sentences are
/// the vocabulary `Prov` absorbs rather than replaces:
///
///   "From open-meteo." · "Only 18 hours of this day were available."
///   "Across 8 sessions — 2 more were left out…"
///   "They move together · 60 matching days"
///   "Nobody has reviewed why these two are related…"
///
/// So these tests check two things per screen: that a `Prov` is there, and
/// that what it says is still the sentence that was written by hand.
/// The chrome a screen needs, without the providers.
///
/// Each test builds its own `ProviderScope` rather than passing overrides in
/// here: riverpod 3 does not export `Override`, so a helper cannot name the
/// type of the list.
/// `scrollable` is for the Column-based sections only. The full screens are
/// `ListView`s already, and nesting one inside a SingleChildScrollView gives
/// the viewport unbounded height.
Widget host(Widget child, {bool scrollable = false}) => MaterialApp(
      theme: AppTheme.build(Brightness.light),
      home: Scaffold(
        body: scrollable ? SingleChildScrollView(child: child) : child,
      ),
    );

// ── Correlations ─────────────────────────────────────────────────────────────

Correlation correlation({
  bool reviewed = false,
  int pairedDays = 60,
  double? effectiveDays = 14.2,
}) =>
    Correlation(
      pairId: 'hrv__sleep_duration',
      first: 'hrv',
      second: 'sleep_duration',
      coefficient: 0.41,
      pairedDays: pairedDays,
      effectiveDays: effectiveDays,
      pValue: 0.004,
      expectedDirection: 'positive',
      mechanism: reviewed ? 'Deeper sleep raises overnight HRV.' : null,
      citation: reviewed ? 'Somebody 2024' : null,
      mechanismReviewed: reviewed,
      withheld: null,
    );

CorrelationReport report({List<Correlation>? reported}) => CorrelationReport(
      modelVersion: 'correlations-v2',
      pairsVersion: 'correlations.v1',
      windowDays: 60,
      tested: 5,
      reported: reported ?? [correlation()],
      withheld: const [],
    );

void main() {
  group('the correlation cards', () {
    testWidgets('a coefficient carries its source, window and basis',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
        correlationReportProvider.overrideWith((ref) async => report()),
      ],
        child: host(const CorrelationsScreen()),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(Prov), findsWidgets);
      expect(find.textContaining('60 matching days'), findsWidgets);
    });

    testWidgets('the effective sample size travels with the coefficient',
        (tester) async {
      // Daily series are not independent samples: over 200 trials of two
      // independent 60-day random walks, 141 cleared p < 0.05 on the raw day
      // count and 7 did on the effective one. The number of days is the
      // reassuring figure and the effective count is the honest one, so the
      // card shows both.
      await tester.pumpWidget(ProviderScope(
        overrides: [
        correlationReportProvider.overrideWith((ref) async => report()),
      ],
        child: host(const CorrelationsScreen()),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('14'), findsWidgets);
    });

    testWidgets('an unreviewed mechanism is said in the provenance',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
        correlationReportProvider.overrideWith((ref) async => report()),
      ],
        child: host(const CorrelationsScreen()),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('Nobody has reviewed'), findsWidgets);
    });

    testWidgets('a signed mechanism is not labelled unreviewed',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
        correlationReportProvider.overrideWith(
            (ref) async => report(reported: [correlation(reviewed: true)])),
      ],
        child: host(const CorrelationsScreen()),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('Deeper sleep raises'), findsOneWidget);
      expect(find.textContaining('Nobody has reviewed'), findsNothing);
    });

    testWidgets('none holding is a result, not an empty list', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
        correlationReportProvider
            .overrideWith((ref) async => report(reported: const [])),
      ],
        child: host(const CorrelationsScreen()),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(Empty), findsOneWidget);
      expect(find.textContaining('That is a result'), findsOneWidget);
    });

    testWidgets('loading says what is being worked out', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
        correlationReportProvider.overrideWith((ref) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return report();
        }),
      ],
        child: host(const CorrelationsScreen()),
      ));
      await tester.pump();

      expect(find.byType(Loading), findsOneWidget);

      // Drained, or the delayed future outlives the widget tree and the
      // binding fails the test on a pending timer.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });
  });

  // ── Therapy effects ───────────────────────────────────────────────────────

  group('the therapy effects', () {
    TherapyEffect effect({bool reviewed = false, int confounded = 2}) =>
        TherapyEffect(
          modality: 'sauna',
          label: 'sauna',
          metric: 'heart_rate',
          meanDelta: 16.4,
          sessions: 8,
          sessionsConfounded: confounded,
          pValue: 0.002,
          mechanism: reviewed ? 'Heat stress drives vasodilation.' : null,
          mechanismReviewed: reviewed,
          withheld: null,
        );

    TherapyEffectReport effects({List<TherapyEffect>? reported}) =>
        TherapyEffectReport(
          minSessions: 5,
          tested: 1,
          reported: reported ?? [effect()],
          withheld: const [],
        );

    testWidgets('a mean delta carries the sessions it was measured across',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
        therapyEffectsProvider.overrideWith((ref) async => effects()),
      ],
        child: host(const TherapyEffectsSection(), scrollable: true),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(Prov), findsWidgets);
      expect(find.textContaining('8 sessions'), findsWidgets);
    });

    testWidgets('the confounded sessions are still accounted for',
        (tester) async {
      // Why the count is lower than the number of sessions somebody remembers
      // doing. Dropping this would make the figure look wrong to the one
      // person who can check it.
      await tester.pumpWidget(ProviderScope(
        overrides: [
        therapyEffectsProvider.overrideWith((ref) async => effects()),
      ],
        child: host(const TherapyEffectsSection(), scrollable: true),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('2 more'), findsWidgets);
    });

    testWidgets('an unreviewed mechanism is said in the provenance',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
        therapyEffectsProvider.overrideWith((ref) async => effects()),
      ],
        child: host(const TherapyEffectsSection(), scrollable: true),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('Nobody has reviewed'), findsWidgets);
    });

    testWidgets('too few sessions reads as too early, not as nothing',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
        therapyEffectsProvider
            .overrideWith((ref) async => effects(reported: const [])),
      ],
        child: host(const TherapyEffectsSection(), scrollable: true),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(Empty), findsOneWidget);
      expect(find.textContaining('5'), findsWidgets);
    });
  });

  // ── Environment ───────────────────────────────────────────────────────────

  group('the environment day cards', () {
    EnvironmentSnapshot day({int hours = 24}) => EnvironmentSnapshot(
          observedOn: DateTime.utc(2026, 10, 11),
          usAqiMean: 92,
          usAqiMax: 181,
          usAqiBand: 'unhealthy',
          pm25Mean: 40,
          uvIndexMax: 9.4,
          uvBand: 'very high',
          hoursObserved: hours,
          provider: 'open-meteo',
        );

    Widget screenWith(List<EnvironmentSnapshot> days) => ProviderScope(
          overrides: [
            chosenPlaceProvider.overrideWithValue(
              const CoarsePlace('Bengaluru', 'Karnataka', 13, 77.6),
            ),
            environmentProvider.overrideWith((ref) async => days),
          ],
          child: host(const EnvironmentSection(), scrollable: true),
        );

    testWidgets('the provider is named on every reading', (tester) async {
      // "The AQI was 181" is a claim somebody else made, and the user is
      // entitled to know who made it.
      await tester.pumpWidget(
          screenWith([day()]));
      await tester.pumpAndSettle();

      expect(find.byType(Prov), findsWidgets);
      expect(find.textContaining('open-meteo'), findsWidgets);
    });

    testWidgets('a part-day says how much of it there was', (tester) async {
      await tester.pumpWidget(
          screenWith([day(hours: 18)]));
      await tester.pumpAndSettle();

      expect(find.textContaining('18'), findsWidgets);
      // And it is not presented as a measured whole day.
      expect(find.textContaining('Estimated'), findsWidgets);
    });

    testWidgets('a whole day is measured, not estimated', (tester) async {
      await tester.pumpWidget(
          screenWith([day()]));
      await tester.pumpAndSettle();

      expect(find.textContaining('Measured'), findsWidgets);
    });

    testWidgets('nothing yet says when the first day arrives', (tester) async {
      await tester.pumpWidget(screenWith(const []));
      await tester.pumpAndSettle();

      expect(find.byType(Empty), findsOneWidget);
      expect(find.textContaining('overnight'), findsOneWidget);
    });
  });
}
