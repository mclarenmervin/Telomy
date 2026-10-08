import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/biological_age/data/epigenetic_entry.dart';

final today = DateTime.utc(2026, 10, 8);

Map<String, String> check({
  String clock = 'horvath',
  String value = '41.3',
  String provider = 'TruDiagnostic',
  DateTime? collectedAt,
}) =>
    validateClockEntry(
      clock: clock,
      value: value,
      provider: provider,
      collectedAt: collectedAt ?? DateTime.utc(2026, 3, 1),
      today: today,
    );

void main() {
  group('a well-formed entry', () {
    test('passes', () => expect(check(), isEmpty));

    test('accepts a pace clock in its own range', () {
      expect(check(clock: 'dunedinpace', value: '0.92'), isEmpty);
    });
  });

  group('the unit is derived, never asked for', () {
    test('an age clock is years', () {
      for (final clock in ['horvath', 'hannum', 'phenoage', 'grimage']) {
        expect(unitFor(clock), 'years', reason: clock);
      }
    });

    test('DunedinPACE is a pace', () {
      // Asking the user to pick a unit invites them to record a rate as an age.
      // The clock determines it, so the form does not offer the choice.
      expect(unitFor('dunedinpace'), 'pace');
    });
  });

  group('the value', () {
    test('must be a number', () {
      expect(check(value: 'forty one')['value'], isNotNull);
      expect(check(value: '')['value'], isNotNull);
    });

    test('must be positive', () {
      expect(check(value: '0')['value'], isNotNull);
      expect(check(value: '-3')['value'], isNotNull);
    });

    test('an age outside a human lifespan is refused', () {
      // A typed 413 for 41.3 is the realistic slip, and it would sit on a chart
      // next to a real result looking like a measurement.
      expect(check(value: '413')['value'], isNotNull);
      expect(check(value: '121')['value'], isNotNull);
    });

    test('a pace is judged on its own scale, not a lifespan', () {
      // 0.92 is a normal DunedinPACE and an absurd age; 45 is the reverse.
      // One range for both would accept nonsense in both directions.
      expect(check(clock: 'dunedinpace', value: '0.92'), isEmpty);
      expect(check(clock: 'dunedinpace', value: '45')['value'], isNotNull);
      expect(check(clock: 'horvath', value: '0.92')['value'], isNotNull);
    });
  });

  group('the provider', () {
    test('is required, because the value is meaningless unattributed', () {
      expect(check(provider: '')['provider'], isNotNull);
      expect(check(provider: '   ')['provider'], isNotNull);
    });
  });

  group('the collection date', () {
    test('cannot be in the future', () {
      expect(
        check(collectedAt: DateTime.utc(2026, 12, 1))['collectedAt'],
        isNotNull,
      );
    });

    test('today is allowed', () {
      expect(check(collectedAt: today), isEmpty);
    });

    test('an implausibly old date is refused', () {
      // Methylation clocks did not exist before Horvath published in 2013, so a
      // 1998 result is a mistyped year.
      expect(check(collectedAt: DateTime.utc(1998, 5, 1))['collectedAt'],
          isNotNull);
    });
  });

  group('the clock', () {
    test('must be one we display', () {
      expect(check(clock: 'my_own_clock')['clock'], isNotNull);
    });
  });

  test('several problems are all reported, not just the first', () {
    // A form that reveals one error at a time makes the user submit repeatedly
    // to discover what is wrong.
    final errors = check(clock: 'nope', value: 'x', provider: '');

    expect(errors.keys.toSet(), {'clock', 'value', 'provider'});
  });
}
