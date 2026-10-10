import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/insights/models/clinical_insight.dart';

/// A finding the user is finally allowed to see.
///
/// Everything upstream of this exists to make one distinction true on screen:
/// either a named clinician read these exact words and signed them, or nobody
/// did. `deliveryRoute` is where that lands, and getting it wrong on the phone
/// would undo the whole phase — an unreviewed observation presented as
/// "reviewed by your doctor" is a worse product than having no review at all.

Map<String, dynamic> signedRow({
  String? disputedAt,
  String? dismissedAt,
  String? reviewerName = 'Dr A. Example',
  String? registration = 'MCI-TEST-0001',
}) => {
      'id': 'f1',
      'kind': 'lab_finding',
      'title': 'HbA1c has risen across 3 results',
      'body': 'HbA1c has risen 11.1%, from 5.4% on 12 February 2026 to '
          '6.0% on 30 September 2026.',
      'evidence': [
        {
          'biomarker_id': 'hba1c',
          'value_canonical': 5.4,
          'unit_canonical': '%',
          'collected_at': '2026-02-12',
          'lab_name': 'Test Labs',
        },
        {
          'biomarker_id': 'hba1c',
          'value_canonical': 6.0,
          'unit_canonical': '%',
          'collected_at': '2026-09-30',
          'lab_name': 'Test Labs',
        },
      ],
      'noticed_by': 'agent',
      'reviewed_at': '2026-10-09T10:00:00Z',
      'reviewer_name': reviewerName,
      'reviewer_registration': registration,
      'delivery_route': 'clinician_signed',
      'delivered_at': '2026-10-09T10:00:05Z',
      'disputed_at': disputedAt,
      'dispute_reason': disputedAt == null ? null : 'My doctor already knows.',
      'dismissed_at': dismissedAt,
    };

Map<String, dynamic> unreviewedRow() => {
      ...signedRow(reviewerName: null, registration: null),
      'reviewed_at': null,
      'delivery_route': 'sla_expired',
    };

/// The evidence is a tagged union from F6 onward: a trend's points are
/// measurements, and a supplement recommendation carries three other shapes.
/// These tests are about the measurement shape, so they say so.
MeasurementEvidence _measurement(InsightEvidence entry) =>
    entry as MeasurementEvidence;

void main() {
  group('the review distinction', () {
    test('a signed insight knows a clinician reviewed it', () {
      final insight = ClinicalInsight.fromRow(signedRow());

      expect(insight.wasReviewed, isTrue);
      expect(insight.reviewerName, 'Dr A. Example');
      expect(insight.reviewerRegistration, 'MCI-TEST-0001');
      expect(insight.reviewedAt, isNotNull);
    });

    test('an SLA-released insight knows nobody reviewed it', () {
      // The queue stalled and we told the user anyway. That is a legitimate
      // thing to do with a statement of arithmetic, and an illegitimate thing
      // to describe as reviewed.
      final insight = ClinicalInsight.fromRow(unreviewedRow());

      expect(insight.wasReviewed, isFalse);
      expect(insight.reviewerName, isNull);
    });

    test('a route we do not recognise is not treated as reviewed', () {
      // A future delivery route, or a typo in a migration. Defaulting to
      // "reviewed" would put a clinician's authority behind something nobody
      // has looked at; defaulting the other way merely understates it.
      final insight = ClinicalInsight.fromRow(
        {...signedRow(), 'delivery_route': 'something_new'},
      );

      expect(insight.wasReviewed, isFalse);
    });

    test('a signed route with no reviewer name is not treated as reviewed', () {
      // The database stamps the name from the signature, so this should be
      // impossible — and if it ever happens, the honest reading is that we
      // cannot say who reviewed it.
      final insight = ClinicalInsight.fromRow(
        signedRow(reviewerName: null, registration: null),
      );

      expect(insight.wasReviewed, isFalse);
    });
  });

  group('what the user has done with it', () {
    test('a new insight is neither disputed nor dismissed', () {
      final insight = ClinicalInsight.fromRow(signedRow());

      expect(insight.isDisputed, isFalse);
      expect(insight.isDismissed, isFalse);
      expect(insight.needsAttention, isTrue);
    });

    test('a dismissed insight no longer needs attention', () {
      final insight = ClinicalInsight.fromRow(
        signedRow(dismissedAt: '2026-10-09T12:00:00Z'),
      );

      expect(insight.isDismissed, isTrue);
      expect(insight.needsAttention, isFalse);
    });

    test('a disputed insight carries the reason the user gave', () {
      // Dismissing is "I have read this". Disputing is "this is wrong about
      // me", and the two must not collapse into one button.
      final insight = ClinicalInsight.fromRow(
        signedRow(disputedAt: '2026-10-09T12:00:00Z'),
      );

      expect(insight.isDisputed, isTrue);
      expect(insight.disputeReason, 'My doctor already knows.');
    });

    test('a disputed insight still needs attention', () {
      // Disagreeing with something is not finishing with it. It stays visible
      // so the dispute is visible too.
      final insight = ClinicalInsight.fromRow(
        signedRow(disputedAt: '2026-10-09T12:00:00Z'),
      );

      expect(insight.needsAttention, isTrue);
    });
  });

  group('the evidence', () {
    test('every point the clinician saw travels to the user', () {
      // The user is entitled to the same workings. An insight whose evidence
      // was dropped is a claim with no trail.
      final insight = ClinicalInsight.fromRow(signedRow());

      expect(insight.evidence, hasLength(2));
      expect(_measurement(insight.evidence.first).value, 5.4);
      expect(_measurement(insight.evidence.last).value, 6.0);
    });

    test('a value is printed the way a lab report prints it', () {
      // F4 shipped "5.4 %" and "Rdw" to a real screen with every test green.
      final insight = ClinicalInsight.fromRow(signedRow());

      expect(_measurement(insight.evidence.first).display, '5.4%');
    });

    test('a non-percentage unit keeps its space', () {
      final insight = ClinicalInsight.fromRow({
        ...signedRow(),
        'evidence': [
          {
            'biomarker_id': 'haemoglobin',
            'value_canonical': 12.4,
            'unit_canonical': 'g/dL',
            'collected_at': '2026-09-30',
          },
        ],
      });

      expect(_measurement(insight.evidence.first).display, '12.4 g/dL');
    });

    test('evidence with no unit does not print a stray space', () {
      final insight = ClinicalInsight.fromRow({
        ...signedRow(),
        'evidence': [
          {'biomarker_id': 'x', 'value_canonical': 3.0, 'collected_at': '2026-01-01'},
        ],
      });

      expect(_measurement(insight.evidence.first).display, '3');
    });

    test('an insight with no evidence is still an insight', () {
      final insight = ClinicalInsight.fromRow({...signedRow(), 'evidence': []});

      expect(insight.evidence, isEmpty);
      expect(insight.body, isNotEmpty);
    });
  });

  group('malformed rows', () {
    test('an empty row does not throw', () {
      // This renders on a screen someone may open in a bad network state. A
      // parse failure must not be what hides a signed finding.
      expect(() => ClinicalInsight.fromRow({}), returnsNormally);
    });

    test('an empty row is not claimed to be reviewed', () {
      expect(ClinicalInsight.fromRow({}).wasReviewed, isFalse);
    });

    test('evidence that is not a list does not throw', () {
      expect(
        () => ClinicalInsight.fromRow({...signedRow(), 'evidence': 'nonsense'}),
        returnsNormally,
      );
    });

    test('an evidence entry that is not a map is skipped', () {
      final insight = ClinicalInsight.fromRow({
        ...signedRow(),
        'evidence': ['nonsense', {'biomarker_id': 'hba1c', 'value_canonical': 6.0}],
      });

      expect(insight.evidence, hasLength(1));
    });

    test('a list of rows parses and keeps the newest first', () {
      final insights = ClinicalInsight.parseRows([
        {...signedRow(), 'id': 'older', 'delivered_at': '2026-01-01T00:00:00Z'},
        {...signedRow(), 'id': 'newer', 'delivered_at': '2026-10-01T00:00:00Z'},
      ]);

      expect([for (final i in insights) i.id], ['newer', 'older']);
    });

    test('one unparseable row does not lose the others', () {
      final insights = ClinicalInsight.parseRows([signedRow(), {}]);

      expect(insights, hasLength(2));
    });
  });
}
