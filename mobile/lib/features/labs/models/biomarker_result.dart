import 'package:flutter/foundation.dart';

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

  bool get isCensored => operator != '=';
  bool get isQualitative => resultType == 'qualitative';

  /// Nothing may be presented as a verdict while this holds.
  bool get hasNoVerdict => grade == 'ungraded';

  /// The value as the report printed it, operator included.
  String get displayValue => isCensored ? '$operator$rawValue' : rawValue;

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
      );
}
