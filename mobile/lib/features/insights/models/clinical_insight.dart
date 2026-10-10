import 'package:flutter/foundation.dart';

/// One piece of evidence a finding rests on.
///
/// The user is entitled to the same workings the clinician saw. An insight
/// whose evidence was dropped on the way to the screen is a claim with no
/// trail, which is the thing this whole phase exists to stop being the case.
@immutable
class InsightEvidence {
  const InsightEvidence({
    required this.biomarkerId,
    required this.value,
    required this.unit,
    required this.collectedAt,
    required this.labName,
  });

  final String biomarkerId;
  final double? value;
  final String unit;
  final DateTime? collectedAt;
  final String? labName;

  /// The value as a lab report would print it.
  ///
  /// No space before a percentage, a space before anything else. F4 shipped
  /// "5.4 %" and "Rdw" to a real screen with every test passing, so the small
  /// typography is tested rather than assumed.
  String get display {
    final v = value;
    if (v == null) return '';
    final text = v == v.roundToDouble() && unit != '%'
        ? v.toStringAsFixed(0)
        : v.toString();
    if (unit.isEmpty) return text;
    return unit == '%' ? '$text$unit' : '$text $unit';
  }

  static InsightEvidence fromMap(Map<String, dynamic> map) => InsightEvidence(
        biomarkerId: map['biomarker_id']?.toString() ?? '',
        value: map['value_canonical'] is num
            ? (map['value_canonical'] as num).toDouble()
            : double.tryParse(map['value_canonical']?.toString() ?? ''),
        unit: map['unit_canonical']?.toString() ?? '',
        collectedAt: DateTime.tryParse(map['collected_at']?.toString() ?? ''),
        labName: map['lab_name']?.toString(),
      );
}

/// Which door a finding came through.
///
/// Not cosmetic. `clinicianSigned` means a named clinician read these exact
/// words and put their registration number against them. `slaExpired` means
/// nobody did: the queue stalled, and we delivered a statement of arithmetic
/// anyway rather than going silent. Presenting the second as the first would
/// put a clinician's authority behind something no clinician has seen, which
/// would be a worse product than having no review workflow at all.
enum DeliveryRoute { clinicianSigned, slaExpired, unknown }

/// A finding the user is finally allowed to see.
///
/// The user-visible end of the clinician spine. Drafts are physically
/// unreadable from here — there is no select policy admitting them — so
/// anything on this screen either carries a signature or openly says it does
/// not.
@immutable
class ClinicalInsight {
  const ClinicalInsight({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.evidence,
    required this.route,
    required this.reviewerName,
    required this.reviewerRegistration,
    required this.reviewedAt,
    required this.deliveredAt,
    required this.disputedAt,
    required this.disputeReason,
    required this.dismissedAt,
  });

  final String id;
  final String kind;
  final String title;

  /// The finding as signed. Rendered as written: a clinician put their
  /// registration number against these words and not against ours.
  final String body;

  final List<InsightEvidence> evidence;
  final DeliveryRoute route;
  final String? reviewerName;
  final String? reviewerRegistration;
  final DateTime? reviewedAt;
  final DateTime? deliveredAt;
  final DateTime? disputedAt;
  final String? disputeReason;
  final DateTime? dismissedAt;

  /// Did a named clinician sign exactly this?
  ///
  /// All three conditions, not just the route. The database stamps the
  /// reviewer's name from the signature it can see, so a signed route without
  /// one should be impossible — and if it ever happens, the honest reading is
  /// that we cannot say who reviewed it. An unrecognised route is not reviewed
  /// either: defaulting the other way would lend a clinician's authority to
  /// whatever a future migration introduces.
  bool get wasReviewed =>
      route == DeliveryRoute.clinicianSigned &&
      (reviewerName?.isNotEmpty ?? false) &&
      reviewedAt != null;

  bool get isDisputed => disputedAt != null;
  bool get isDismissed => dismissedAt != null;

  /// Disagreeing with something is not finishing with it, so a disputed
  /// insight stays visible — which keeps the dispute visible too.
  bool get needsAttention => !isDismissed || isDisputed;

  static DeliveryRoute _route(String? raw) => switch (raw) {
        'clinician_signed' => DeliveryRoute.clinicianSigned,
        'sla_expired' => DeliveryRoute.slaExpired,
        _ => DeliveryRoute.unknown,
      };

  static List<InsightEvidence> _evidence(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map) InsightEvidence.fromMap(Map<String, dynamic>.from(entry)),
    ];
  }

  static ClinicalInsight fromRow(Map<String, dynamic> row) => ClinicalInsight(
        id: row['id']?.toString() ?? '',
        kind: row['kind']?.toString() ?? '',
        title: row['title']?.toString() ?? '',
        body: row['body']?.toString() ?? '',
        evidence: _evidence(row['evidence']),
        route: _route(row['delivery_route']?.toString()),
        reviewerName: row['reviewer_name']?.toString(),
        reviewerRegistration: row['reviewer_registration']?.toString(),
        reviewedAt:
            DateTime.tryParse(row['reviewed_at']?.toString() ?? '')?.toLocal(),
        deliveredAt:
            DateTime.tryParse(row['delivered_at']?.toString() ?? '')?.toLocal(),
        disputedAt:
            DateTime.tryParse(row['disputed_at']?.toString() ?? '')?.toLocal(),
        disputeReason: row['dispute_reason']?.toString(),
        dismissedAt:
            DateTime.tryParse(row['dismissed_at']?.toString() ?? '')?.toLocal(),
      );

  /// Newest first, and one unparseable row never loses the others. A finding a
  /// clinician signed must not disappear because a neighbouring row was odd.
  static List<ClinicalInsight> parseRows(List<Map<String, dynamic>> rows) {
    final parsed = [for (final row in rows) fromRow(row)];
    parsed.sort((a, b) {
      final left = a.deliveredAt;
      final right = b.deliveredAt;
      if (left == null && right == null) return 0;
      if (left == null) return 1;
      if (right == null) return -1;
      return right.compareTo(left);
    });
    return parsed;
  }
}
