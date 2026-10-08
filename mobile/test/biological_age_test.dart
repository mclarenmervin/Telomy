import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/biological_age/data/biological_age_view.dart';
import 'package:telomy/features/scores/models/score_snapshot.dart';

/// A server-computed biological age row, as `score_snapshots` holds it.
Map<String, dynamic> row({
  num? value = 43.2,
  String asOf = '2026-06-15',
  String quality = 'full',
  List<String> missing = const [],
  List<Map<String, dynamic>> drivers = const [
    {
      'name': 'rdw',
      'score': 1.8,
      'weight': 0.3306,
      'detail': '13.5 % against an optimal 12.25 %: +1.8 years',
    }
  ],
}) => {
      'user_id': 'u1',
      'score_kind': 'biological_age',
      'as_of_date': asOf,
      'value': value,
      'drivers': drivers,
      'missing_inputs': missing,
      'data_quality': quality,
      'model_version': 'biological-age-phenoage-levine-2018-v1',
      'ranges_version': 'global.v1',
      'timezone': 'Asia/Kolkata',
      'inputs_hash': 'sha256:abc',
      'computed_at': '2026-06-16T03:00:00',
    };

ScoreSnapshot snap(Map<String, dynamic> r) =>
    ScoreSnapshot.fromRow(r, kind: 'biological_age')!;

void main() {
  group('a biological age is rendered, never computed here', () {
    test('keeps the fraction the server sent', () {
      // Readiness is a whole number and `value` rounds for it. An age of 43.2
      // shown as 43 is a different claim, and rounding one of the two scores to
      // suit the other is how the dual-math defect starts again.
      expect(snap(row()).exactValue, 43.2);
    });

    test('carries its drivers so the screen need not derive them', () {
      final view = BiologicalAgeView.of(snap(row()));

      expect(view.drivers.single.name, 'rdw');
      expect(view.drivers.single.detail, contains('+1.8 years'));
    });

    test('is dated to the blood draw, not to today', () {
      expect(BiologicalAgeView.of(snap(row())).asOf, DateTime.utc(2026, 6, 15));
    });

    test('reports the model it came from', () {
      expect(
        BiologicalAgeView.of(snap(row())).modelVersion,
        startsWith('biological-age-phenoage'),
      );
    });
  });

  group('why there is no number', () {
    test('no snapshot at all is not-computed, not zero', () {
      final view = BiologicalAgeView.of(null);

      expect(view.state, BiologicalAgeState.notComputed);
      expect(view.exactValue, isNull);
    });

    test('an unreviewed catalog is reported as awaiting review', () {
      // The F4 decision: the server withholds the number while
      // biomarkers.v1.yaml is unreviewed, and says so in missing_inputs.
      final view = BiologicalAgeView.of(snap(row(
        value: null,
        quality: 'none',
        missing: ['clinical_review'],
        drivers: const [],
      )));

      expect(view.state, BiologicalAgeState.awaitingClinicalReview);
    });

    test('awaiting review wins over a short panel', () {
      // Both can be true at once. Telling someone to go and get an MCV would be
      // misleading while no panel, however complete, would produce a number.
      final view = BiologicalAgeView.of(snap(row(
        value: null,
        quality: 'none',
        missing: ['clinical_review', 'mcv'],
        drivers: const [],
      )));

      expect(view.state, BiologicalAgeState.awaitingClinicalReview);
    });

    test('missing markers are named so the user can act on them', () {
      final view = BiologicalAgeView.of(snap(row(
        value: null,
        quality: 'none',
        missing: ['mcv', 'alkaline_phosphatase'],
        drivers: const [],
      )));

      expect(view.state, BiologicalAgeState.needsLabs);
      expect(view.missingMarkers, ['alkaline_phosphatase', 'mcv']);
    });

    test('a rejected result is explained rather than called missing', () {
      // The server sends `marker:reason`. "We need a fasting glucose" is
      // actionable; "glucose missing" is something the user can see is false.
      final view = BiologicalAgeView.of(snap(row(
        value: null,
        quality: 'none',
        missing: ['glucose_fasting:wrong_context'],
        drivers: const [],
      )));

      expect(view.state, BiologicalAgeState.needsLabs);
      expect(view.missingMarkers, ['glucose_fasting']);
      expect(view.reasonFor('glucose_fasting'), 'wrong_context');
    });

    test('a missing date of birth is a profile gap, not a lab gap', () {
      final view = BiologicalAgeView.of(snap(row(
        value: null,
        quality: 'none',
        missing: ['date_of_birth'],
        drivers: const [],
      )));

      expect(view.state, BiologicalAgeState.needsProfile);
    });

    test('pregnancy is a refusal to score and says so in its own right', () {
      // Reference ranges shift substantially and the model stops being valid.
      // Rendering this as "add more data" would invite the user to keep trying.
      final view = BiologicalAgeView.of(snap(row(
        value: null,
        quality: 'none',
        missing: ['pregnancy'],
        drivers: const [],
      )));

      expect(view.state, BiologicalAgeState.notApplicable);
    });

    test('being under the minimum age is also not-applicable', () {
      final view = BiologicalAgeView.of(snap(row(
        value: null,
        quality: 'none',
        missing: ['under_minimum_age'],
        drivers: const [],
      )));

      expect(view.state, BiologicalAgeState.notApplicable);
    });

    test('a profile gap is reported before a lab gap', () {
      // Fixing the date of birth is one tap; the labs are a blood draw.
      final view = BiologicalAgeView.of(snap(row(
        value: null,
        quality: 'none',
        missing: ['date_of_birth', 'mcv'],
        drivers: const [],
      )));

      expect(view.state, BiologicalAgeState.needsProfile);
    });
  });

  group('what the screen is allowed to say', () {
    test('every state has a sentence that does not imply a number', () {
      for (final state in BiologicalAgeState.values) {
        final text = messageFor(state);
        expect(text, isNotEmpty, reason: '$state');
        expect(text, isNot(contains('0')), reason: '$state');
      }
    });

    test('the ready state is the only one that offers a value', () {
      expect(BiologicalAgeView.of(snap(row())).hasValue, isTrue);
      for (final state in BiologicalAgeState.values) {
        if (state != BiologicalAgeState.ready) {
          expect(offersAValue(state), isFalse, reason: '$state');
        }
      }
    });
  });
}
