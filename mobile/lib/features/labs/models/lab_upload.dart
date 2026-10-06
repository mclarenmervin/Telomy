import 'package:flutter/foundation.dart';

/// An uploaded lab report, as the server has read it.
///
/// The app renders this; it does not re-derive any of it. The three dates are
/// deliberately separate fields because they are three different facts, and
/// trending uses `collectedAt` alone.
@immutable
class LabUpload {
  const LabUpload({
    required this.id,
    required this.status,
    required this.collectedAt,
    required this.collectedAtSource,
    required this.reportedAt,
    required this.patientName,
    required this.labName,
    required this.isHistory,
    required this.pageCount,
    required this.error,
  });

  final String id;
  final String status;

  /// When the sample was taken. Null when extraction could not read it, which
  /// is a question for the user rather than a value to invent.
  final DateTime? collectedAt;

  /// `extracted`, `user` or `unknown`. Anything but `extracted` means we are
  /// not confident and must ask before the report is trusted on a chart.
  final String collectedAtSource;

  final DateTime? reportedAt;

  /// The name printed on the report. The document may be a family member's, so
  /// this is shown and a mismatch blocks ingestion.
  final String? patientName;

  final String? labName;

  /// Older than the history window: it populates trends and raises no alerts.
  final bool isHistory;

  final int? pageCount;

  /// Why it failed, in words a person can act on.
  final String? error;

  bool get isAwaitingConfirmation => status == 'extracted';
  bool get needsPassword => status == 'needs_password';
  bool get hasFailed => status == 'failed';
  bool get isConfirmed => status == 'confirmed';

  /// We read a date but are not sure of it, or we read none at all.
  bool get collectionDateIsUncertain => collectedAtSource != 'extracted';

  static DateTime? _date(Object? value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString())?.toLocal();
  }

  /// An empty name is the same as no name: it must not produce a confirmation
  /// prompt asking whether the user is "".
  static String? _name(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static LabUpload fromRow(Map<String, dynamic> row) => LabUpload(
        id: row['id']?.toString() ?? '',
        status: row['status']?.toString() ?? 'uploaded',
        collectedAt: _date(row['collected_at']),
        collectedAtSource: row['collected_at_source']?.toString() ?? 'unknown',
        reportedAt: _date(row['reported_at']),
        patientName: _name(row['patient_name']),
        labName: row['lab_name']?.toString(),
        isHistory: row['is_history'] == true,
        pageCount: (row['page_count'] as num?)?.toInt(),
        error: row['error']?.toString(),
      );
}
