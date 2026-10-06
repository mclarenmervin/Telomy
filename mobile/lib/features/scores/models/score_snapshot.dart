import 'package:flutter/foundation.dart';

/// A score computed on the server, with the provenance needed to explain it.
///
/// The app renders this rather than recomputing it. That is what stops
/// readiness being calculated twice, with two sets of constants, giving two
/// answers that can never be reconciled.
@immutable
class ScoreDriver {
  const ScoreDriver({
    required this.name,
    required this.score,
    required this.weight,
    required this.detail,
  });

  final String name;
  final double score;
  final double weight;
  final String detail;

  static ScoreDriver? fromJson(Map<String, dynamic> json) {
    final name = json['name']?.toString();
    if (name == null || name.isEmpty) return null;
    return ScoreDriver(
      name: name,
      score: (json['score'] as num?)?.toDouble() ?? 0,
      weight: (json['weight'] as num?)?.toDouble() ?? 0,
      detail: json['detail']?.toString() ?? '',
    );
  }
}

@immutable
class ScoreSnapshot {
  const ScoreSnapshot({
    required this.kind,
    required this.asOf,
    required this.value,
    required this.drivers,
    required this.missingInputs,
    required this.dataQuality,
    required this.modelVersion,
    required this.timezone,
    this.rangesVersion,
    this.computedAt,
  });

  final String kind;
  final DateTime asOf;

  /// Null means unknown. It does not mean zero, and must never render as one.
  final int? value;
  final List<ScoreDriver> drivers;
  final List<String> missingInputs;
  final String dataQuality; // full | partial | none
  final String modelVersion;

  /// The timezone that defined the day. A score is about someone's day, and
  /// whose day it was is part of what the number means.
  final String timezone;
  final String? rangesVersion;
  final DateTime? computedAt;

  bool get hasValue => value != null;
  bool get isComplete => dataQuality == 'full';

  static ScoreSnapshot? fromRow(Map<String, dynamic> row, {String? kind}) {
    final rowKind = row['score_kind']?.toString();
    if (rowKind == null || (kind != null && rowKind != kind)) return null;

    final asOf = DateTime.tryParse(row['as_of_date']?.toString() ?? '');
    if (asOf == null) return null;

    final drivers = <ScoreDriver>[];
    for (final raw in (row['drivers'] as List? ?? const [])) {
      if (raw is Map) {
        final driver = ScoreDriver.fromJson(Map<String, dynamic>.from(raw));
        if (driver != null) drivers.add(driver);
      }
    }

    return ScoreSnapshot(
      kind: rowKind,
      asOf: DateTime.utc(asOf.year, asOf.month, asOf.day),
      value: (row['value'] as num?)?.round(),
      drivers: drivers,
      missingInputs: (row['missing_inputs'] as List? ?? const [])
          .map((m) => m.toString())
          .toList(),
      dataQuality: row['data_quality']?.toString() ?? 'none',
      modelVersion: row['model_version']?.toString() ?? 'unknown',
      timezone: row['timezone']?.toString() ?? 'UTC',
      rangesVersion: row['ranges_version']?.toString(),
      computedAt: DateTime.tryParse(row['computed_at']?.toString() ?? ''),
    );
  }
}
