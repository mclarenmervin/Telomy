import 'package:flutter/foundation.dart';

import '../../biological_age/data/biological_age_view.dart'
    show markerLabel;

/// One value read off a report, awaiting the user's confirmation.
///
/// `grade` comes from the server and is `ungraded` until a clinician has signed
/// the reference-range catalog off. The app must render that as "no verdict" —
/// not as a neutral or passing result — because the absence of a grade is a
/// statement about our confidence, not about the user's health.
@immutable
class BiomarkerResult {
  const BiomarkerResult({
    required this.id,
    required this.biomarkerId,
    required this.context,
    required this.resultType,
    required this.operator,
    required this.rawValue,
    required this.rawUnit,
    required this.valueCanonical,
    required this.unitCanonical,
    required this.grade,
    required this.page,
    required this.confidence,
    required this.bbox,
    required this.collectedAt,
  });

  final String id;
  final String biomarkerId;

  /// `standard`, `fasting`, `post_prandial`, `random`. What separates a fasting
  /// glucose from a post-prandial one taken in the same draw.
  final String context;

  final String resultType;

  /// `=`, `<` or `>`. A censored result is displayable but its true value is
  /// unknown, so it is excluded from biological age and correlations.
  final String operator;

  /// Exactly as printed on the report. This is what the user checks against,
  /// so it is never reformatted.
  final String rawValue;

  final String? rawUnit;
  final double? valueCanonical;
  final String? unitCanonical;

  /// `ungraded` while the catalog is unreviewed.
  final String grade;

  /// Zero-based page the value was read from, for "from page 2".
  final int? page;

  /// Lower when the marker was identified by a model rather than the catalog's
  /// alias table, and lower again when the text came from OCR. Worth
  /// surfacing: those deserve a closer look.
  final double? confidence;

  /// Where on the page this was read from, with the page extent. What lets the
  /// screen show the user the crop of their own report.
  final Map<String, dynamic>? bbox;

  /// When the sample was taken -- not when it was reported or uploaded. This
  /// is the only date a trend may use.
  final DateTime? collectedAt;

  bool get isCensored => operator != '=';
  bool get isQualitative => resultType == 'qualitative';

  /// Nothing may be presented as a verdict while this holds.
  bool get hasNoVerdict => grade == 'ungraded';

  /// The value as the report printed it, operator included.
  String get displayValue => isCensored ? '$operator$rawValue' : rawValue;

  /// The marker as a person would read it, with the context when it changes
  /// what the number means. Fasting and post-prandial glucose are one marker
  /// and two results, and a list showing both as "glucose fasting" twice is
  /// not a list anyone can use.
  ///
  /// Goes through [markerLabel] rather than tidying up the id. Substituting
  /// spaces for underscores gives "hba1c", "wbc" and "vitamin d 25oh" — which
  /// is what this list actually read on a device, with every test passing,
  /// because the tests asserted the identifier. The same bug as F4's "Rdw"
  /// and "Hs crp", one layer along.
  String get displayLabel {
    final name = markerLabel(biomarkerId);
    if (context == 'standard') return name;
    return '$name (${context.replaceAll('_', ' ')})';
  }

  /// What the report said, with its unit.
  ///
  /// No space before a percentage, a space before everything else, and an
  /// empty unit omitted rather than leaving a trailing space. No lab report
  /// prints "7.8 %", and a user checking the screen against their own PDF
  /// should be reading the same string on both.
  String get displayValueWithUnit {
    final unit = rawUnit ?? unitCanonical ?? '';
    if (unit.isEmpty) return displayValue;
    return unit == '%' ? '$displayValue$unit' : '$displayValue $unit';
  }

  static BiomarkerResult fromRow(Map<String, dynamic> row) => BiomarkerResult(
        id: row['id']?.toString() ?? '',
        biomarkerId: row['biomarker_id']?.toString() ?? '',
        context: row['context']?.toString() ?? 'standard',
        resultType: row['result_type']?.toString() ?? 'quantitative',
        operator: row['operator']?.toString() ?? '=',
        rawValue: row['raw_value']?.toString() ?? '',
        rawUnit: row['raw_unit']?.toString(),
        valueCanonical: (row['value_canonical'] as num?)?.toDouble(),
        unitCanonical: row['unit_canonical']?.toString(),
        grade: row['grade']?.toString() ?? 'ungraded',
        page: (row['page'] as num?)?.toInt(),
        confidence: (row['confidence'] as num?)?.toDouble(),
        bbox: row['bbox'] == null
            ? null
            : Map<String, dynamic>.from(row['bbox'] as Map),
        collectedAt: row['collected_at'] == null
            ? null
            : DateTime.tryParse(row['collected_at'].toString())?.toLocal(),
      );
}
