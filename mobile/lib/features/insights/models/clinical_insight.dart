import 'package:flutter/foundation.dart';

/// One piece of evidence a finding rests on.
///
/// The user is entitled to the same workings the clinician saw. An insight
/// whose evidence was dropped on the way to the screen is a claim with no
/// trail, which is the thing this whole phase exists to stop being the case.
///
/// A tagged union rather than one wide class, because F6's evidence is not all
/// one shape. A trend rests on a series of measurements; a supplement
/// recommendation rests on a measurement, the reference range it fell below,
/// the reviewed rule that was applied, and the medications that complicate it.
/// Read as one shape, three of those four render as a marker label with no
/// number beside it — a blank row under "Based on", which reads as a missing
/// result rather than as something the app could not display. That is the same
/// class of bug F4 shipped as "Rdw" and F5 shipped as a dispute box promising a
/// reviewer who did not exist, so the kinds are distinct types and the switch
/// over them has to be exhaustive.
///
/// `summary` is what the card prints. It lives on the data rather than in the
/// widget so that "every entry has something to print" is a test over the model
/// instead of a screenshot somebody has to look at.
sealed class InsightEvidence {
  const InsightEvidence();

  /// The one line this entry contributes under "Based on". Never empty.
  String get summary;

  /// An entry whose `kind` is absent is a measurement: every insight F5
  /// delivered carries evidence in that shape and they are still on people's
  /// phones. A discriminator that broke them would be a migration disguised as
  /// a feature.
  static InsightEvidence fromMap(Map<String, dynamic> map) =>
      switch (map['kind']?.toString()) {
        'reference_range' => RangeEvidence.fromMap(map),
        'rule' => RuleEvidence.fromMap(map),
        'interaction' => InteractionEvidence.fromMap(map),
        null || '' || 'measurement' => MeasurementEvidence.fromMap(map),
        final kind => UnknownEvidence(kind),
      };
}

/// A measured value, as the lab reported it.
@immutable
class MeasurementEvidence extends InsightEvidence {
  const MeasurementEvidence({
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

  @override
  String get summary => display;

  static MeasurementEvidence fromMap(Map<String, dynamic> map) =>
      MeasurementEvidence(
        biomarkerId: map['biomarker_id']?.toString() ?? '',
        value: _number(map['value_canonical']),
        unit: map['unit_canonical']?.toString() ?? '',
        collectedAt: DateTime.tryParse(map['collected_at']?.toString() ?? ''),
        labName: map['lab_name']?.toString(),
      );
}

/// The reference range a value was judged against.
///
/// Carried with its version, because a range edited tomorrow must not
/// retroactively change what the user was told today.
@immutable
class RangeEvidence extends InsightEvidence {
  const RangeEvidence({
    required this.biomarkerId,
    required this.low,
    required this.high,
    required this.unit,
    required this.rangesVersion,
    required this.citation,
  });

  final String biomarkerId;
  final double? low;
  final double? high;
  final String unit;
  final String? rangesVersion;
  final String? citation;

  String get printedRange {
    if (low == null || high == null) return '';
    return '${_plain(low!)}–${_plain(high!)}${unit.isEmpty ? '' : ' $unit'}';
  }

  @override
  String get summary {
    final range = printedRange;
    return range.isEmpty ? 'Standard range unavailable' : 'Standard range $range';
  }

  static RangeEvidence fromMap(Map<String, dynamic> map) => RangeEvidence(
        biomarkerId: map['biomarker_id']?.toString() ?? '',
        low: _number(map['standard_low']),
        high: _number(map['standard_high']),
        unit: map['unit_canonical']?.toString() ?? '',
        rangesVersion: map['ranges_version']?.toString(),
        citation: map['citation']?.toString(),
      );
}

/// The reviewed rule that was applied, and who signed it.
///
/// Two signatures stand behind a delivered supplement insight: the clinician
/// who signed this finding, and the clinician who signed the rule it rests on.
/// The second one is invisible unless the evidence carries it.
@immutable
class RuleEvidence extends InsightEvidence {
  const RuleEvidence({
    required this.ruleId,
    required this.supplement,
    required this.citation,
    required this.reviewer,
    required this.reviewedAt,
  });

  final String ruleId;
  final String supplement;
  final String? citation;
  final String? reviewer;
  final String? reviewedAt;

  @override
  String get summary =>
      supplement.isEmpty ? 'Guideline applied' : 'Suggested: $supplement';

  static RuleEvidence fromMap(Map<String, dynamic> map) => RuleEvidence(
        ruleId: map['rule_id']?.toString() ?? '',
        supplement: map['supplement']?.toString() ?? '',
        citation: map['citation']?.toString(),
        reviewer: map['reviewer']?.toString(),
        reviewedAt: map['reviewed_at']?.toString(),
      );
}

/// A medication of the user's that changes the answer.
///
/// `recordedAs` is what the person typed, not the term that matched it: a line
/// reading "Tab. Metformin 500mg" is recognisable to them in a way that
/// "metformin" is not.
@immutable
class InteractionEvidence extends InsightEvidence {
  const InteractionEvidence({
    required this.medication,
    required this.recordedAs,
    required this.note,
  });

  final String medication;
  final String recordedAs;
  final String note;

  @override
  String get summary {
    final named = recordedAs.isNotEmpty ? recordedAs : medication;
    return named.isEmpty ? 'A medication was considered' : 'Considered: $named';
  }

  static InteractionEvidence fromMap(Map<String, dynamic> map) =>
      InteractionEvidence(
        medication: map['medication']?.toString() ?? '',
        recordedAs: map['recorded_as']?.toString() ?? '',
        note: map['note']?.toString() ?? '',
      );
}

/// An evidence shape this version of the app does not know.
///
/// Kept rather than dropped, and named rather than rendered as a measurement.
/// Dropping it would hide from the user that the finding rests on something
/// they are not being shown; rendering it as a measurement would print a label
/// with no value, which reads as a result that went missing.
@immutable
class UnknownEvidence extends InsightEvidence {
  const UnknownEvidence(this.kind);

  final String kind;

  @override
  String get summary => 'Supporting detail this app version cannot show';
}

double? _number(Object? raw) => raw is num
    ? raw.toDouble()
    : double.tryParse(raw?.toString() ?? '');

/// 30, not 30.0. A range printed with a trailing zero reads like a precision
/// the reference interval does not have.
String _plain(double value) =>
    value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

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

  /// A recommendation rather than an observation.
  ///
  /// The distinction the card has to draw, because this is the first kind of
  /// insight the user can be told to act on. It can only ever arrive signed --
  /// the database refuses to deliver a flagged draft without a signature -- so
  /// the card may lean on `wasReviewed` being true here, and the model test
  /// says so in case a future migration widens that gate.
  bool get isSupplement => kind == 'supplement';

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
