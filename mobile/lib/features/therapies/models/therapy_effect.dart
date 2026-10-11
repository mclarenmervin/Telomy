/// What a run of one kind of therapy session did to one measured signal.
///
/// Decided on the server, like a correlation: how many sessions it took, what
/// the change was, whether it could be chance, and whether it ran the way the
/// therapy is expected to. The phone renders and does not judge.
class TherapyEffect {
  const TherapyEffect({
    required this.modality,
    required this.label,
    required this.metric,
    required this.meanDelta,
    required this.sessions,
    required this.sessionsConfounded,
    required this.pValue,
    required this.mechanism,
    required this.mechanismReviewed,
    required this.withheld,
  });

  final String modality;

  /// The modality in the words the catalog uses — "sauna", "cold plunge".
  final String label;
  final String metric;

  /// After minus before, averaged across sessions. A change, never a level.
  final double? meanDelta;
  final int sessions;

  /// Sessions dropped because something else the user logged overlapped them.
  /// Worth showing when it is not zero: it is why the count is lower than the
  /// number they remember doing.
  final int sessionsConfounded;
  final double? pValue;

  /// Null until a clinician has signed the explanation off, which is the case
  /// for everything today.
  final String? mechanism;
  final bool mechanismReviewed;

  final String? withheld;

  bool get isReported => withheld == null;
  bool get rose => (meanDelta ?? 0) >= 0;

  factory TherapyEffect.fromJson(Map<String, dynamic> json) => TherapyEffect(
        modality: json['modality']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        metric: json['metric']?.toString() ?? '',
        meanDelta: (json['mean_delta'] as num?)?.toDouble(),
        sessions: (json['sessions'] as num?)?.toInt() ?? 0,
        sessionsConfounded: (json['sessions_confounded'] as num?)?.toInt() ?? 0,
        pValue: (json['p_value'] as num?)?.toDouble(),
        mechanism: json['mechanism']?.toString(),
        mechanismReviewed: json['mechanism_reviewed'] == true,
        withheld: json['withheld']?.toString(),
      );
}

class TherapyEffectReport {
  const TherapyEffectReport({
    required this.minSessions,
    required this.tested,
    required this.reported,
    required this.withheld,
  });

  final int minSessions;
  final int tested;
  final List<TherapyEffect> reported;
  final List<TherapyEffect> withheld;

  bool get isEmpty => reported.isEmpty;

  factory TherapyEffectReport.fromJson(Map<String, dynamic> json) {
    List<TherapyEffect> parse(String key) => [
          for (final row in (json[key] as List? ?? const []))
            TherapyEffect.fromJson(Map<String, dynamic>.from(row as Map)),
        ];
    return TherapyEffectReport(
      minSessions: (json['min_sessions'] as num?)?.toInt() ?? 5,
      tested: (json['tested'] as num?)?.toInt() ?? 0,
      reported: parse('reported'),
      withheld: parse('withheld'),
    );
  }
}

/// Human labels for the signals the engine tracks.
///
/// A map rather than a formatter: "hrv" must render as "HRV" and "spo2" as
/// "Blood oxygen", and F4 shipped "Rdw" and "Hs crp" to a real screen doing
/// it the other way with every test green.
const metricLabels = <String, String>{
  'heartRate': 'Heart rate',
  'hrv': 'HRV',
  'temperature': 'Skin temperature',
  'spo2': 'Blood oxygen',
};

const metricUnits = <String, String>{
  'heartRate': 'bpm',
  'hrv': 'ms',
  'temperature': '°C',
  'spo2': '%',
};

String metricLabel(String id) => metricLabels[id] ?? id;

String metricUnit(String id) => metricUnits[id] ?? '';

/// Why a tested effect is not being shown, in the user's words.
String therapyWithheldReason(String reason, int minSessions) =>
    switch (reason) {
      'too_few_sessions' =>
        'We need at least $minSessions sessions before this means anything.',
      'not_significant' => 'Your sessions disagreed with each other too much.',
      'direction_mismatch' =>
        'This changed the opposite way to what this therapy usually does, so '
            'something else was probably going on and we cannot put it down '
            'to the session.',
      _ => 'Not reportable.',
    };
