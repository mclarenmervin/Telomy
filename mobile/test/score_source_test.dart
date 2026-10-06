import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/scores/models/score_snapshot.dart';
import 'package:telomy/features/scores/data/score_source.dart';

Map<String, dynamic> row({
  num? value = 72,
  String asOf = '2026-10-01',
  String quality = 'full',
  List<String> missing = const [],
  String model = 'readiness-v1',
}) => {
      'user_id': 'u1',
      'score_kind': 'readiness',
      'as_of_date': asOf,
      'value': value,
      'drivers': [
        {'name': 'HRV', 'score': 80.0, 'weight': 0.22, 'detail': '60 vs 55'}
      ],
      'missing_inputs': missing,
      'data_quality': quality,
      'model_version': model,
      'ranges_version': null,
      'timezone': 'Asia/Kolkata',
      'inputs_hash': 'sha256:abc',
      'computed_at': '2026-10-02T03:00:00',
    };

void main() {
  group('ScoreSnapshot', () {
    test('parses a server row with its provenance', () {
      final snapshot = ScoreSnapshot.fromRow(row())!;

      expect(snapshot.value, 72);
      expect(snapshot.modelVersion, 'readiness-v1');
      expect(snapshot.timezone, 'Asia/Kolkata');
      expect(snapshot.drivers.single.name, 'HRV');
      expect(snapshot.asOf, DateTime.utc(2026, 10, 1));
    });

    test('a null value is unknown, not zero', () {
      final snapshot = ScoreSnapshot.fromRow(row(value: null, quality: 'none'))!;

      expect(snapshot.value, isNull);
      expect(snapshot.hasValue, isFalse);
    });

    test('missing inputs are surfaced so the screen can say what is absent', () {
      final snapshot =
          ScoreSnapshot.fromRow(row(quality: 'partial', missing: ['Stress']))!;

      expect(snapshot.missingInputs, ['Stress']);
      expect(snapshot.isComplete, isFalse);
    });

    test('a row for another score kind is rejected', () {
      expect(ScoreSnapshot.fromRow({...row(), 'score_kind': 'longi'},
          kind: 'readiness'), isNull);
    });

    test('a row with no date is rejected rather than half-built', () {
      expect(ScoreSnapshot.fromRow({...row(), 'as_of_date': null}), isNull);
    });
  });

  group('choosing which number to show', () {
    final server = ScoreSnapshot.fromRow(row())!;
    final day = DateTime.utc(2026, 10, 1);

    test('the server score is used when it covers the day asked for', () {
      final resolved = resolveScore(server: server, offline: 68, forDay: day);

      expect(resolved.origin, ScoreOrigin.server);
      expect(resolved.value, 72);
      expect(resolved.modelVersion, 'readiness-v1');
    });

    test('the offline estimate is used when the server has nothing', () {
      final resolved = resolveScore(server: null, offline: 68, forDay: day);

      expect(resolved.origin, ScoreOrigin.offline);
      expect(resolved.value, 68);
    });

    test('an offline estimate declares its own model version', () {
      /// It must never be mistaken for the server number in a screenshot or a
      /// support conversation.
      final resolved = resolveScore(server: null, offline: 68, forDay: day);

      expect(resolved.modelVersion, offlineModelVersion);
      expect(resolved.modelVersion, isNot('readiness-v1'));
    });

    test('a server snapshot for a different day is not used for today', () {
      final stale = ScoreSnapshot.fromRow(row(asOf: '2026-09-20'))!;

      final resolved = resolveScore(server: stale, offline: 68, forDay: day);

      expect(resolved.origin, ScoreOrigin.offline);
    });

    test('nothing at all is an empty state, not a zero', () {
      final resolved = resolveScore(server: null, offline: null, forDay: day);

      expect(resolved.origin, ScoreOrigin.none);
      expect(resolved.value, isNull);
    });

    test('a server snapshot with no value falls back to the offline estimate', () {
      final empty = ScoreSnapshot.fromRow(row(value: null, quality: 'none'))!;

      final resolved = resolveScore(server: empty, offline: 68, forDay: day);

      expect(resolved.origin, ScoreOrigin.offline);
    });
  });

  group('shadow comparison', () {
    final server = ScoreSnapshot.fromRow(row())!;

    test('agreement reports no divergence', () {
      expect(divergenceBetween(server: server, offline: 72), 0);
    });

    test('disagreement reports the signed difference', () {
      /// Signed, because a server number consistently four points low is a
      /// different bug from one that is noisy either way.
      expect(divergenceBetween(server: server, offline: 68), 4);
      expect(divergenceBetween(server: server, offline: 75), -3);
    });

    test('no comparison is possible when either side is absent', () {
      expect(divergenceBetween(server: server, offline: null), isNull);
      expect(divergenceBetween(server: null, offline: 68), isNull);
    });
  });
}
