import 'package:flutter/foundation.dart';

/// An epigenetic clock result the user got from somebody else.
///
/// **We never compute one of these.** A Horvath, Hannum, PhenoAge-DNAm, GrimAge
/// or DunedinPACE result comes from a methylation array run by a provider the
/// user paid, and `epigenetic_results` pins `source` to `third_party` in a check
/// constraint so nothing can write a value there and call it ours.
///
/// That distinction is the whole reason this is a separate model from the
/// biological age we do compute. They are both "a number of years about your
/// body" and they must never be presented as the same kind of claim: ours comes
/// from blood chemistry on a model we can cite and reproduce, theirs from DNA
/// methylation on a model we have no access to.
///
/// So three things are load-bearing here and a row missing any of them is
/// dropped rather than shown: the provider, the collection date, and a clock we
/// actually recognise.

/// The clocks `epigenetic_results` permits, matching the table's own check
/// constraint. A value outside this set is dropped rather than rendered, or a
/// raw database string ends up in front of a user as a label.
const knownClocks = {
  'horvath',
  'hannum',
  'phenoage',
  'grimage',
  'dunedinpace',
};

const _labels = {
  'horvath': 'Horvath clock',
  'hannum': 'Hannum clock',
  // Named to keep it apart from the PhenoAge we compute from blood chemistry.
  // Same paper, different input: this one is read off a methylation array.
  'phenoage': 'DNAm PhenoAge',
  'grimage': 'GrimAge',
  'dunedinpace': 'DunedinPACE',
};

/// Clocks that report a *rate* of ageing rather than an age. Rendering 0.92 as
/// "0.92 years" is nonsense and as "0.92 years old" is alarming nonsense.
const _paceClocks = {'dunedinpace'};

@immutable
class EpigeneticClock {
  const EpigeneticClock({
    required this.clock,
    required this.value,
    required this.unit,
    required this.provider,
    required this.collectedAt,
  });

  final String clock;
  final double value;
  final String unit;

  /// Who measured it. Not decoration -- this is what stops the number reading
  /// as ours, so a row without one is not shown at all.
  final String provider;

  final DateTime collectedAt;

  String get label => _labels[clock] ?? clock;

  bool get isPace => _paceClocks.contains(clock) || unit == 'pace';

  /// The value with its unit, in the only form that is true for this clock.
  String get display => isPace
      ? '${_trim(value)}x per year'
      : '${_trim(value)} ${unit.isEmpty ? 'years' : unit}';

  static String _trim(double value) =>
      value == value.roundToDouble() && value.abs() < 1000
          ? value.toStringAsFixed(1)
          : value.toString();

  /// A clock from a `epigenetic_results` row, or null when the row cannot be
  /// shown honestly.
  static EpigeneticClock? fromRow(Map<String, dynamic> row) {
    final clock = row['clock']?.toString();
    if (clock == null || !knownClocks.contains(clock)) return null;

    // Anything but third_party means something wrote a value here and called
    // it ours. The table forbids it; this is the second lock.
    if (row['source']?.toString() != 'third_party') return null;

    final provider = row['provider']?.toString() ?? '';
    if (provider.trim().isEmpty) return null;

    final value = (row['value'] as num?)?.toDouble();
    if (value == null) return null;

    final collectedAt = DateTime.tryParse(row['collected_at']?.toString() ?? '');
    if (collectedAt == null) return null;

    return EpigeneticClock(
      clock: clock,
      value: value,
      unit: row['unit']?.toString() ?? '',
      provider: provider,
      collectedAt: collectedAt,
    );
  }
}

/// Usable clocks from a set of rows, newest first.
///
/// Different clocks disagree by years on the same sample. They are all kept and
/// none is averaged or reconciled: the disagreement is a property of the clocks
/// and hiding it would be the more misleading choice.
List<EpigeneticClock> parseClocks(List<Map<String, dynamic>> rows) {
  final clocks = <EpigeneticClock>[];
  for (final row in rows) {
    final clock = EpigeneticClock.fromRow(row);
    if (clock != null) clocks.add(clock);
  }
  clocks.sort((a, b) => b.collectedAt.compareTo(a.collectedAt));
  return clocks;
}
