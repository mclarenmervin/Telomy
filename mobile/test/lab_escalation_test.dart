import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/labs/models/lab_escalation.dart';

/// A critical value the user has to actually see.
///
/// The worker writes these before anything is confirmed and regardless of
/// review state, because a critical value cannot wait for a clinician queue.
/// None of that matters if the app never surfaces them — a finding written to
/// a table no screen reads has not escalated anything, which is exactly how
/// this behaved until now.

Map<String, dynamic> row({String? acknowledged}) => {
      'id': 'e1',
      'biomarker_id': 'haemoglobin',
      'message': 'One value in this report (Haemoglobin 4.1 g/dL) is far '
          'outside the range we would expect. Please have it reviewed by a '
          'doctor promptly.',
      'acknowledged_at': acknowledged,
      'created_at': '2026-10-07T09:00:00Z',
    };

void main() {
  test('a new finding is outstanding', () {
    expect(LabEscalation.fromRow(row()).isOutstanding, isTrue);
  });

  test('an acknowledged finding is not', () {
    expect(
      LabEscalation.fromRow(row(acknowledged: '2026-10-07T10:00:00Z'))
          .isOutstanding,
      isFalse,
    );
  });

  test('the message is shown as the server wrote it', () {
    // The wording is non-diagnostic on purpose, and the catalog it fired on is
    // unreviewed. The app must not compose its own version of this sentence.
    final e = LabEscalation.fromRow(row());

    expect(e.message, contains('far outside the range'));
    expect(e.message, contains('doctor'));
    for (final claim in ['anaemia', 'anemia', 'diagnos', 'you have']) {
      expect(e.message.toLowerCase(), isNot(contains(claim)));
    }
  });

  test('a malformed row does not throw', () {
    // This renders on a screen someone may open in a bad network state. A
    // parse failure must not be the thing that hides a critical value.
    expect(() => LabEscalation.fromRow({}), returnsNormally);
  });
}
