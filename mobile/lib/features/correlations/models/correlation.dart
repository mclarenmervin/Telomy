/// One tested pair, exactly as the server decided it.
///
/// Nothing here computes and nothing here judges. The phone used to run its
/// own Pearson over forty-five pairs with no correction and print "Strong
/// pattern" on whatever came out; the whole point of the rewrite is that the
/// decision of what may be shown is made once, on the server, where the
/// mechanism catalog and the false discovery rate live.
class Correlation {
  const Correlation({
    required this.pairId,
    required this.first,
    required this.second,
    required this.coefficient,
    required this.pairedDays,
    required this.effectiveDays,
    required this.pValue,
    required this.expectedDirection,
    required this.mechanism,
    required this.citation,
    required this.mechanismReviewed,
    required this.withheld,
  });

  final String pairId;
  final String first;
  final String second;

  /// Null only for a pair that could not be tested at all.
  final double? coefficient;
  final int pairedDays;

  /// How many independent observations those days actually carry. Lower than
  /// [pairedDays] whenever consecutive days resemble each other, which for a
  /// resting heart rate is nearly always.
  final double? effectiveDays;
  final double? pValue;
  final String? expectedDirection;

  /// Why these two move together — null until a clinician has signed that
  /// explanation off, which is the case for every pair today. When it is null
  /// the screen says two series moved together and says nothing about why.
  final String? mechanism;
  final String? citation;
  final bool mechanismReviewed;

  /// Null for a reported pair; otherwise the reason it did not qualify.
  final String? withheld;

  bool get isReported => withheld == null;

  /// Only ever "together" or "oppositely". Deliberately not "causes".
  String get direction =>
      (coefficient ?? 0) >= 0 ? 'move together' : 'move oppositely';

  static double? _asDouble(Object? value) =>
      value is num ? value.toDouble() : null;

  factory Correlation.fromJson(Map<String, dynamic> json) => Correlation(
        pairId: json['pair_id']?.toString() ?? '',
        first: json['first']?.toString() ?? '',
        second: json['second']?.toString() ?? '',
        coefficient: _asDouble(json['coefficient']),
        pairedDays: (json['paired_days'] as num?)?.toInt() ?? 0,
        effectiveDays: _asDouble(json['effective_days']),
        pValue: _asDouble(json['p_value']),
        expectedDirection: json['expected_direction']?.toString(),
        mechanism: json['mechanism']?.toString(),
        citation: json['citation']?.toString(),
        mechanismReviewed: json['mechanism_reviewed'] == true,
        withheld: json['withheld']?.toString(),
      );
}

/// A whole run: what was tested, what held, and what did not.
class CorrelationReport {
  const CorrelationReport({
    required this.modelVersion,
    required this.pairsVersion,
    required this.windowDays,
    required this.tested,
    required this.reported,
    required this.withheld,
  });

  final String modelVersion;
  final String pairsVersion;
  final int windowDays;

  /// How many hypotheses were tested. Shown, because it is what makes the
  /// rest readable: "none of the five we tested held" is a finding and
  /// "nothing found" is not.
  final int tested;

  final List<Correlation> reported;
  final List<Correlation> withheld;

  bool get isEmpty => reported.isEmpty;

  factory CorrelationReport.fromJson(Map<String, dynamic> json) {
    List<Correlation> parse(String key) => [
          for (final row in (json[key] as List? ?? const []))
            Correlation.fromJson(Map<String, dynamic>.from(row as Map)),
        ];
    return CorrelationReport(
      modelVersion: json['model_version']?.toString() ?? '',
      pairsVersion: json['pairs_version']?.toString() ?? '',
      windowDays: (json['window_days'] as num?)?.toInt() ?? 90,
      tested: (json['tested'] as num?)?.toInt() ?? 0,
      reported: parse('reported'),
      withheld: parse('withheld'),
    );
  }
}

/// Human labels for the series ids the server uses.
///
/// A map rather than a format-the-id helper, because "hrv" must render as
/// "HRV" and not "Hrv" — F4 shipped "Rdw" and "Hs crp" to a real screen doing
/// exactly that, and everything was green.
const seriesLabels = <String, String>{
  'sleep_duration': 'Sleep',
  'steps': 'Steps',
  'active_minutes': 'Active minutes',
  'resting_heart_rate': 'Resting heart rate',
  'hrv': 'HRV',
  'stress': 'Stress',
  'food_energy': 'Food energy',
  'protein': 'Protein',
  'hydration': 'Hydration',
  'workout_minutes': 'Workout minutes',
};

String seriesLabel(String id) => seriesLabels[id] ?? id;

/// Why a tested pair is not being shown, in the user's words.
String withheldReason(String reason, int windowDays) => switch (reason) {
      'too_few_days' => 'Not enough days with both recorded yet.',
      'weak' => 'Any pattern here is too small to be worth reporting.',
      'not_significant' =>
        'What movement there is could easily be chance over $windowDays days.',
      'direction_mismatch' =>
        'These moved together, but opposite to the way they usually do — so we '
            'cannot explain it, and we would rather not guess.',
      _ => 'Not reportable.',
    };
