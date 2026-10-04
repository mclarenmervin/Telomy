import 'package:flutter/foundation.dart';

/// The `predictions.kind` values this screen understands.
///
/// `activity_summary` is deliberately absent: that row belongs to the workout
/// report screen, and both feeds arrive on the same Realtime channel.
enum EventPredictionKind { ack, checkIn, analysis }

const _checkInPrefix = 'check_in:';

/// One thing the agent said about an event — the acknowledgement when it starts,
/// a mid-event check-in while it runs, or the analysis once it ends.
@immutable
class EventCheckIn {
  const EventCheckIn({
    required this.eventId,
    required this.kind,
    required this.summary,
    required this.createdAt,
    this.reason,
    this.needsEscalation = false,
  });

  final String eventId;
  final EventPredictionKind kind;
  final String summary;
  final DateTime createdAt;

  /// For a check-in: which rule fired (`hr_elevated`, `hrv_suppressed`,
  /// `spo2_low`). Null for an ack or an analysis. The backend delivers each
  /// reason at most once per event, so this doubles as the identity of the row.
  final String? reason;

  /// The backend's deterministic guardrail decided this reading warrants
  /// seeking care. Surfaced as a property so the UI never has to parse a list.
  final bool needsEscalation;

  bool get isCheckIn => kind == EventPredictionKind.checkIn;

  static EventCheckIn? fromRow(Map<String, dynamic> row) {
    final eventId = row['event_id']?.toString();
    final rawKind = row['kind']?.toString() ?? '';
    final summary = (row['summary']?.toString() ?? '').trim();
    if (eventId == null || eventId.isEmpty || summary.isEmpty) return null;

    EventPredictionKind kind;
    String? reason;
    if (rawKind == 'ack') {
      kind = EventPredictionKind.ack;
    } else if (rawKind == 'analysis') {
      kind = EventPredictionKind.analysis;
    } else if (rawKind.startsWith(_checkInPrefix)) {
      reason = rawKind.substring(_checkInPrefix.length);
      if (reason.isEmpty) return null;
      kind = EventPredictionKind.checkIn;
    } else {
      // activity_summary, or a kind from a newer backend than this build.
      return null;
    }

    final flags = (row['guardrail_flags'] as List? ?? const [])
        .map((f) => f.toString())
        .toList();

    return EventCheckIn(
      eventId: eventId,
      kind: kind,
      summary: summary,
      reason: reason,
      needsEscalation: flags.contains('escalation'),
      // A row always has created_at in Postgres; a Realtime payload could still
      // arrive without it, and sorting oldest is safer than dropping the row.
      createdAt:
          DateTime.tryParse(row['created_at']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}
