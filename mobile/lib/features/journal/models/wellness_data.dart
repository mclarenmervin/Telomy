import '../../health/models/health_measurement.dart';
import 'journal_entry.dart';

class WellnessData {
  const WellnessData({
    this.profile = const {},
    this.entries = const [],
    this.measurements = const [],
    this.ring = const {},
    this.demo = false,
  });
  final Map<String, String> profile;
  final List<JournalEntry> entries;
  final List<HealthMeasurement> measurements;
  final Map<String, dynamic> ring;
  final bool demo;
  double goal(String key, double fallback) =>
      double.tryParse(profile[key] ?? '') ?? fallback;
  WellnessData copyWith({
    Map<String, String>? profile,
    List<JournalEntry>? entries,
    List<HealthMeasurement>? measurements,
    Map<String, dynamic>? ring,
    bool? demo,
  }) => WellnessData(
    profile: profile ?? this.profile,
    entries: entries ?? this.entries,
    measurements: measurements ?? this.measurements,
    ring: ring ?? this.ring,
    demo: demo ?? this.demo,
  );
  Map<String, dynamic> toJson() => {
    'version': 1,
    'profile': profile,
    'entries': entries.map((e) => e.toJson()).toList(),
    'measurements': measurements.map((m) => m.toJson()).toList(),
    'ring': ring,
    'demo': demo,
  };
  factory WellnessData.fromJson(Map<String, dynamic> json) => WellnessData(
    profile: Map<String, String>.from(json['profile'] as Map? ?? {}),
    entries: (json['entries'] as List? ?? [])
        .map((e) => JournalEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    measurements: (json['measurements'] as List? ?? [])
        .map(
          (m) =>
              HealthMeasurement.fromJson(Map<String, dynamic>.from(m as Map)),
        )
        .toList(),
    ring: Map<String, dynamic>.from(json['ring'] as Map? ?? {}),
    demo: json['demo'] == true,
  );
}
