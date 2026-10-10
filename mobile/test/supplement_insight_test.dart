import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/insights/models/clinical_insight.dart';

/// A supplement recommendation, once a clinician has signed it.
///
/// The first insight the user can be told to *act* on, and the first whose
/// evidence is not all one shape. A trend rests on a series of measurements; a
/// recommendation rests on a measurement, the reference range it fell below,
/// the reviewed rule that was applied, and the medications that complicate it.
///
/// Those four shapes are why this file exists. F4 shipped "Rdw" and "5.4 %" to
/// a real screen with every test green, and F5 shipped a dispute box promising
/// "the clinician who reviewed it" on a card whose badge said nobody had. An
/// evidence entry the app cannot read does not fail loudly — it renders as a
/// blank row under "Based on", which is the same class of bug one phase later.

Map<String, dynamic> supplementRow({List<Object>? evidence}) => {
      'id': 's1',
      'kind': 'supplement',
      'title': 'Vitamin D (25-OH) is below the standard range',
      'body': 'Vitamin D (25-OH) was 14 ng/mL on 30 September 2026, below the '
          'standard range of 30–100 ng/mL. Vitamin D supplementation is the '
          'usual response to a level this low, at a dose and duration a '
          'clinician sets.',
      'evidence': evidence ??
          [
            {
              'kind': 'measurement',
              'biomarker_id': 'vitamin_d_25oh',
              'value_canonical': 14,
              'unit_canonical': 'ng/mL',
              'collected_at': '2026-09-30',
              'context': 'standard',
              'lab_name': 'Thyrocare',
            },
            {
              'kind': 'reference_range',
              'biomarker_id': 'vitamin_d_25oh',
              'standard_low': 30,
              'standard_high': 100,
              'unit_canonical': 'ng/mL',
              'ranges_version': 'global.v1',
              'citation': 'Holick MF et al. PMID 21646368',
            },
            {
              'kind': 'rule',
              'rule_id': 'vitamin_d_repletion',
              'supplement': 'Vitamin D3 (cholecalciferol)',
              'trigger': 'below_standard',
              'citation': 'Holick MF et al. PMID 21646368',
              'reviewer': 'Dr A. Example, MBBS MD, reg. 12345',
              'reviewed_at': '2026-10-10',
            },
          ],
      'noticed_by': 'agent',
      'reviewed_at': '2026-10-10T10:00:00Z',
      'reviewer_name': 'Dr M. Raghavan',
      'reviewer_registration': 'KMC-2019-44871',
      'delivery_route': 'clinician_signed',
      'delivered_at': '2026-10-10T10:00:05Z',
      'disputed_at': null,
      'dispute_reason': null,
      'dismissed_at': null,
    };

void main() {
  group('the kind', () {
    test('a supplement insight knows it is one', () {
      expect(ClinicalInsight.fromRow(supplementRow()).isSupplement, isTrue);
    });

    test('a lab finding is not a supplement', () {
      final row = {...supplementRow(), 'kind': 'lab_finding'};

      expect(ClinicalInsight.fromRow(row).isSupplement, isFalse);
    });

    test('a supplement recommendation always carries a signature', () {
      // Not a property of the card but of the phase: the database refuses to
      // deliver a flagged draft without one. Asserted here so that a future
      // migration which widened the gate shows up as a failing expectation on
      // the phone as well as in SQL.
      expect(ClinicalInsight.fromRow(supplementRow()).wasReviewed, isTrue);
    });
  });

  group('the four evidence shapes', () {
    List<InsightEvidence> parse([List<Object>? evidence]) =>
        ClinicalInsight.fromRow(supplementRow(evidence: evidence)).evidence;

    test('a measurement carries the value as a report prints it', () {
      final entry = parse().whereType<MeasurementEvidence>().single;

      expect(entry.biomarkerId, 'vitamin_d_25oh');
      expect(entry.display, '14 ng/mL');
      expect(entry.labName, 'Thyrocare');
    });

    test('an entry with no kind is still a measurement', () {
      // Every insight F5 delivered has evidence in this shape, and they are
      // still on people's phones. A discriminator that broke them would be a
      // migration disguised as a feature.
      final entry = parse([
        {
          'biomarker_id': 'hba1c',
          'value_canonical': 6.0,
          'unit_canonical': '%',
          'collected_at': '2026-09-30',
          'lab_name': 'Test Labs',
        }
      ]).single;

      expect(entry, isA<MeasurementEvidence>());
      expect((entry as MeasurementEvidence).display, '6.0%');
    });

    test('a reference range carries the bounds the value fell below', () {
      final entry = parse().whereType<RangeEvidence>().single;

      expect(entry.printedRange, '30–100 ng/mL');
      expect(entry.citation, contains('Holick'));
    });

    test('a rule carries the supplement and the clinician who signed it', () {
      final entry = parse().whereType<RuleEvidence>().single;

      expect(entry.supplement, 'Vitamin D3 (cholecalciferol)');
      expect(entry.reviewer, contains('Dr A. Example'));
      expect(entry.citation, contains('PMID'));
    });

    test('an interaction carries the medication as the person recorded it', () {
      final entry = parse([
        {
          'kind': 'interaction',
          'medication': 'spironolactone',
          'recorded_as': 'Spironolactone 25mg',
          'note': 'Potassium-sparing diuretics retain magnesium.',
        }
      ]).single;

      expect(entry, isA<InteractionEvidence>());
      expect((entry as InteractionEvidence).recordedAs, 'Spironolactone 25mg');
    });

    test('an unrecognised kind is kept, not read as a measurement', () {
      // The honest failure. A future evidence shape rendered as a measurement
      // prints a marker label with no number beside it, which reads as a
      // missing result rather than as something this version cannot show.
      final entry = parse([
        {'kind': 'genetic_variant', 'rsid': 'rs1801133'}
      ]).single;

      expect(entry, isA<UnknownEvidence>());
    });

    test('every entry has something to print', () {
      // The blank-row test. An entry that renders as an empty line under
      // "Based on" is the F4 and F5 bug in a new place.
      for (final entry in parse()) {
        expect(entry.summary.trim(), isNotEmpty, reason: entry.toString());
      }
    });
  });
}
