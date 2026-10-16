class TherapyPlanItem {
  const TherapyPlanItem({
    required this.id,
    required this.catalogueId,
    required this.name,
    required this.disposition,
    required this.prescribedDose,
    required this.frequency,
    this.safetyExplanation,
  });
  final String id, catalogueId, name, disposition;
  final Map<String, dynamic> prescribedDose, frequency;
  final String? safetyExplanation;
  bool get excludedForSafety => disposition == 'excluded_safety';

  factory TherapyPlanItem.fromJson(
    Map<String, dynamic> json,
  ) => TherapyPlanItem(
    id: json['id']?.toString() ?? '',
    catalogueId: json['catalogue_id']?.toString() ?? '',
    name:
        json['name']?.toString() ??
        json['modality_id']?.toString() ??
        'Therapy',
    disposition: json['disposition']?.toString() ?? 'proposed',
    prescribedDose:
        (json['prescribed_dose'] as Map?)?.cast<String, dynamic>() ?? const {},
    frequency: (json['frequency'] as Map?)?.cast<String, dynamic>() ?? const {},
    safetyExplanation: json['safety_explanation']?.toString(),
  );
}

class TherapyPlan {
  const TherapyPlan({
    required this.id,
    required this.patientId,
    required this.centreId,
    required this.version,
    required this.status,
    required this.contentSha256,
    required this.items,
  });
  final String id, patientId, centreId, status, contentSha256;
  final int version;
  final List<TherapyPlanItem> items;
  bool get signed => status == 'signed';

  factory TherapyPlan.fromJson(Map<String, dynamic> json) => TherapyPlan(
    id: json['id']?.toString() ?? '',
    patientId: json['patient_id']?.toString() ?? '',
    centreId: json['centre_id']?.toString() ?? '',
    version: (json['version'] as num?)?.toInt() ?? 1,
    status: json['status']?.toString() ?? 'proposed',
    contentSha256: json['content_sha256']?.toString() ?? '',
    items: [
      for (final item in json['items'] as List? ?? const [])
        TherapyPlanItem.fromJson((item as Map).cast<String, dynamic>()),
    ],
  );
}
