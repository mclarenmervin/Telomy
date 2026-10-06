import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/scores/data/shadow_log.dart';

void main() {
  test('an agreement is recorded as a clean day', () {
    final log = ShadowLog();

    log.record(kind: 'readiness', day: DateTime.utc(2026, 10, 1), divergence: 0);

    expect(log.cleanDays, 1);
    expect(log.divergentDays, 0);
    expect(log.isClean, isTrue);
  });

  test('a disagreement is recorded with its size', () {
    final log = ShadowLog();

    log.record(kind: 'readiness', day: DateTime.utc(2026, 10, 1), divergence: 4);

    expect(log.divergentDays, 1);
    expect(log.worstDivergence, 4);
    expect(log.isClean, isFalse);
  });

  test('the worst divergence is by magnitude, not sign', () {
    final log = ShadowLog()
      ..record(kind: 'readiness', day: DateTime.utc(2026, 10, 1), divergence: 3)
      ..record(kind: 'readiness', day: DateTime.utc(2026, 10, 2), divergence: -9);

    expect(log.worstDivergence, -9);
  });

  test('the same day recorded twice counts once', () {
    /// The screen can rebuild many times a day; that is not new evidence.
    final log = ShadowLog()
      ..record(kind: 'readiness', day: DateTime.utc(2026, 10, 1), divergence: 0)
      ..record(kind: 'readiness', day: DateTime.utc(2026, 10, 1), divergence: 0);

    expect(log.cleanDays, 1);
  });

  test('a day with no comparison available is not counted either way', () {
    /// Absence of evidence is not evidence of agreement.
    final log = ShadowLog()
      ..record(kind: 'readiness', day: DateTime.utc(2026, 10, 1), divergence: null);

    expect(log.cleanDays, 0);
    expect(log.divergentDays, 0);
    expect(log.isClean, isFalse, reason: 'no data is not a clean result');
  });

  test('clean requires the full shadow window, not merely no disagreements', () {
    final log = ShadowLog(requiredCleanDays: 14);

    for (var d = 1; d <= 13; d++) {
      log.record(kind: 'readiness', day: DateTime.utc(2026, 10, d), divergence: 0);
    }
    expect(log.isReadyToSwitch, isFalse);

    log.record(kind: 'readiness', day: DateTime.utc(2026, 10, 14), divergence: 0);
    expect(log.isReadyToSwitch, isTrue);
  });

  test('one divergent day blocks the switch however many clean ones follow', () {
    final log = ShadowLog(requiredCleanDays: 3)
      ..record(kind: 'readiness', day: DateTime.utc(2026, 10, 1), divergence: 2);

    for (var d = 2; d <= 10; d++) {
      log.record(kind: 'readiness', day: DateTime.utc(2026, 10, d), divergence: 0);
    }

    expect(log.isReadyToSwitch, isFalse,
        reason: 'a known disagreement must be explained, not waited out');
  });
}
