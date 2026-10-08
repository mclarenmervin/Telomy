import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/biological_age/models/epigenetic_clock.dart';

Map<String, dynamic> row({
  String clock = 'horvath',
  num value = 41.3,
  String unit = 'years',
  String provider = 'TruDiagnostic',
  String collectedAt = '2026-03-01T00:00:00+00:00',
  String source = 'third_party',
}) => {
      'clock': clock,
      'value': value,
      'unit': unit,
      'provider': provider,
      'collected_at': collectedAt,
      'source': source,
    };

void main() {
  group('a third-party clock is displayed, never computed', () {
    test('parses a row with its provider', () {
      final clock = EpigeneticClock.fromRow(row())!;

      expect(clock.clock, 'horvath');
      expect(clock.value, 41.3);
      expect(clock.provider, 'TruDiagnostic');
    });

    test('a row without a provider is dropped rather than shown anonymously', () {
      // "Your biological age is 41.3" with no attribution invites the user to
      // read someone else's measurement as ours. Better to show nothing.
      expect(EpigeneticClock.fromRow(row(provider: '')), isNull);
    });

    test('a row claiming to be our own computation is dropped', () {
      // The table pins `source` to third_party in a check constraint, so this
      // cannot happen from the server. Checked anyway: the one thing that must
      // never appear is our name against a number we did not produce.
      expect(EpigeneticClock.fromRow(row(source: 'computed')), isNull);
    });

    test('a row with no collection date is dropped', () {
      expect(EpigeneticClock.fromRow(row(collectedAt: '')), isNull);
    });

    test('an unrecognised clock is dropped rather than labelled by its id', () {
      // Rendering a raw `my_own_clock` in a list of named clocks is how a
      // database value ends up in front of a user as a label.
      expect(EpigeneticClock.fromRow(row(clock: 'my_own_clock')), isNull);
    });
  });

  group('how a clock is labelled', () {
    test('each known clock has a human name', () {
      for (final id in knownClocks) {
        final clock = EpigeneticClock.fromRow(row(clock: id))!;
        expect(clock.label, isNotEmpty, reason: id);
        expect(clock.label, isNot(contains('_')), reason: id);
      }
    });

    test('an age reads in years', () {
      expect(EpigeneticClock.fromRow(row(value: 41.3))!.display, '41.3 years');
    });

    test('a pace is a rate and never reads as an age', () {
      // DunedinPACE is years of ageing per year. "0.92 years" is nonsense and
      // "0.92 years old" is alarming nonsense.
      final pace = EpigeneticClock.fromRow(
        row(clock: 'dunedinpace', value: 0.92, unit: 'pace'),
      )!;

      expect(pace.display, isNot(contains('years old')));
      expect(pace.display, contains('0.92'));
      expect(pace.isPace, isTrue);
      expect(pace.display, contains('per year'));
    });

    test('a clock that is an age is not treated as a pace', () {
      expect(EpigeneticClock.fromRow(row())!.isPace, isFalse);
    });
  });

  group('a list of clocks', () {
    test('comes back newest first', () {
      final clocks = parseClocks([
        row(collectedAt: '2024-01-01T00:00:00+00:00', value: 46),
        row(collectedAt: '2026-03-01T00:00:00+00:00', value: 41.3),
      ]);

      expect(clocks.map((c) => c.value), [41.3, 46]);
    });

    test('keeps clocks that disagree rather than reconciling them', () {
      // Horvath, Hannum and GrimAge differ by years on one sample. That is a
      // property of the clocks, not an error to average away.
      final clocks = parseClocks([
        row(clock: 'horvath', value: 41.3),
        row(clock: 'grimage', value: 48.1),
        row(clock: 'hannum', value: 44.0),
      ]);

      expect(clocks.length, 3);
      expect(clocks.map((c) => c.clock).toSet(),
          {'horvath', 'grimage', 'hannum'});
    });

    test('drops the unusable rows and keeps the rest', () {
      final clocks = parseClocks([
        row(),
        row(clock: 'nonsense'),
        row(provider: ''),
      ]);

      expect(clocks.length, 1);
    });

    test('no rows is an empty list, not an error', () {
      expect(parseClocks(const []), isEmpty);
    });
  });
}
