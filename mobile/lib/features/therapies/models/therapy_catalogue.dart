class TherapyCatalogueItem {
  const TherapyCatalogueItem({
    required this.id, required this.slug, required this.name,
    required this.category, required this.summary,
    required this.intendedExperience, required this.contraindicationRuleIds,
    required this.doseSchema,
  });

  final String id, slug, name, category, summary, intendedExperience;
  final List<String> contraindicationRuleIds;
  final Map<String, dynamic> doseSchema;

  factory TherapyCatalogueItem.fromJson(Map<String, dynamic> json) => TherapyCatalogueItem(
    id: json['id']?.toString() ?? '', slug: json['slug']?.toString() ?? '',
    name: json['display_name']?.toString() ?? json['slug']?.toString() ?? '',
    category: json['category']?.toString() ?? '',
    summary: json['summary']?.toString() ?? '',
    intendedExperience: json['intended_experience']?.toString() ?? '',
    contraindicationRuleIds: [for (final value in json['contraindication_rule_ids'] as List? ?? const []) value.toString()],
    doseSchema: (json['dose_schema'] as Map?)?.cast<String, dynamic>() ?? const {},
  );
}

class TherapyOffering {
  const TherapyOffering({
    required this.id, required this.centreId, required this.catalogueId,
    required this.indicativePriceMinor, required this.currencyCode,
    this.defaultDurationMinutes,
  });
  final String id, centreId, catalogueId, currencyCode;
  final int indicativePriceMinor;
  final int? defaultDurationMinutes;

  String get indicativePrice =>
      'Indicative $currencyCode ${(indicativePriceMinor / 100).toStringAsFixed(2)}';

  factory TherapyOffering.fromJson(Map<String, dynamic> json) => TherapyOffering(
    id: json['id']?.toString() ?? '', centreId: json['centre_id']?.toString() ?? '',
    catalogueId: json['catalogue_id']?.toString() ?? '',
    indicativePriceMinor: (json['indicative_price_minor'] as num?)?.toInt() ?? 0,
    currencyCode: json['currency_code']?.toString() ?? '',
    defaultDurationMinutes: (json['default_duration_minutes'] as num?)?.toInt(),
  );
}

String safetyFactLabel(String id) {
  final words = id.split('_').join(' ');
  return words.isEmpty ? words : '${words[0].toUpperCase()}${words.substring(1)}';
}
