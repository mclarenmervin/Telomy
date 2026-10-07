import 'package:flutter/foundation.dart';

/// A value far enough outside the expected range that it should not wait.
///
/// Written by the extraction worker before the user has confirmed anything and
/// independent of any review state, because the clinician queue is for
/// recommendations and never for emergencies. The message is deliberately
/// non-diagnostic: the ranges it fired on have not been reviewed, so naming a
/// condition would be a medical claim we cannot support.
///
/// The app's only job is to make sure it is *seen*. A finding written to a
/// table no screen reads has not escalated anything.
@immutable
class LabEscalation {
  const LabEscalation({
    required this.id,
    required this.biomarkerId,
    required this.message,
    required this.acknowledgedAt,
    required this.createdAt,
  });

  final String id;
  final String biomarkerId;

  /// Already phrased for a person. The app shows it as written rather than
  /// composing its own wording, so there is one place this can be got wrong.
  final String message;

  /// When the person marked it seen. Null means still outstanding.
  final DateTime? acknowledgedAt;

  final DateTime? createdAt;

  bool get isOutstanding => acknowledgedAt == null;

  static LabEscalation fromRow(Map<String, dynamic> row) => LabEscalation(
        id: row['id']?.toString() ?? '',
        biomarkerId: row['biomarker_id']?.toString() ?? '',
        message: row['message']?.toString() ?? '',
        acknowledgedAt: row['acknowledged_at'] == null
            ? null
            : DateTime.tryParse(row['acknowledged_at'].toString())?.toLocal(),
        createdAt: row['created_at'] == null
            ? null
            : DateTime.tryParse(row['created_at'].toString())?.toLocal(),
      );
}
