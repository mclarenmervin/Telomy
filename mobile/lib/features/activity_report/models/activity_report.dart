import 'dart:convert';

/// The structured report the backend agent writes to `predictions.analysis`.
///
/// Parsing is deliberately tolerant: `score` is absent until the user has enough
/// history, sections may be empty, and new fields must not break older clients.
class ReportScore {
  const ReportScore({
    required this.value,
    required this.scale,
    required this.label,
    required this.basis,
  });

  final int value;
  final int scale;
  final String label;
  final String basis;

  static ReportScore? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final value = json['value'];
    if (value is! num) return null;
    return ReportScore(
      value: value.round(),
      scale: (json['scale'] as num?)?.round() ?? 100,
      label: (json['label'] as String?) ?? '',
      basis: (json['basis'] as String?) ?? '',
    );
  }
}

class ReportSection {
  const ReportSection({required this.id, required this.title, required this.body});

  final String id;
  final String title;
  final String body;

  static ReportSection fromJson(Map<String, dynamic> json) => ReportSection(
    id: (json['id'] as String?) ?? '',
    title: (json['title'] as String?) ?? '',
    body: ((json['body'] as String?) ?? '').trim(),
  );
}

class ReportMetric {
  const ReportMetric({
    required this.key,
    required this.value,
    this.baseline,
    this.delta,
    this.direction,
    this.severity = 'normal',
    this.note = '',
  });

  final String key;
  final num value;
  final num? baseline;
  final num? delta;
  final String? direction;

  /// Computed by the backend, never by the model. Drives this row's colour.
  final String severity;

  /// A plain-English line so a number reads as an insight.
  final String note;

  /// A readable label for the metric keys the ring reports.
  String get label => const {
    'heartRate': 'Heart rate',
    'hrv': 'HRV',
    'spo2': 'Blood oxygen',
    'stress': 'Stress',
    'steps': 'Steps',
  }[key] ?? key;

  String get unit => const {
    'heartRate': ' bpm',
    'spo2': '%',
    'hrv': ' ms',
  }[key] ?? '';

  static ReportMetric? fromJson(Map<String, dynamic> json) {
    final value = json['value'];
    if (value is! num) return null;
    return ReportMetric(
      key: (json['key'] as String?) ?? '',
      value: value,
      baseline: json['baseline'] as num?,
      delta: json['delta'] as num?,
      direction: json['direction'] as String?,
      severity: (json['severity'] as String?) ?? 'normal',
      note: ((json['note'] as String?) ?? '').trim(),
    );
  }
}

/// The one route the report offers to act on a finding. Deliberately has no phone
/// number: the app deep-links to its own consultations flow instead.
class ReportEscalation {
  const ReportEscalation({
    required this.level,
    required this.title,
    required this.body,
    required this.action,
  });

  final String level; // routine | recommended | urgent
  final String title;
  final String body;
  final String action;

  bool get isProminent => level == 'recommended' || level == 'urgent';

  static ReportEscalation? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final level = (json['level'] as String?) ?? '';
    if (level.isEmpty) return null;
    return ReportEscalation(
      level: level,
      title: (json['title'] as String?) ?? 'Book a consultation',
      body: ((json['body'] as String?) ?? '').trim(),
      action: (json['action'] as String?) ?? 'book_consultation',
    );
  }
}

class ActivityReport {
  const ActivityReport({
    required this.sessionId,
    required this.eventType,
    required this.headline,
    required this.sections,
    required this.metrics,
    required this.dataQuality,
    required this.sessionsCompared,
    this.score,
    this.narrationIncomplete = false,
    this.severity = 'normal',
    this.escalation,
  });

  final String sessionId;
  final String eventType;
  final String headline;
  final List<ReportSection> sections;
  final List<ReportMetric> metrics;
  final String dataQuality;
  final int sessionsCompared;
  final ReportScore? score;

  /// Report-level severity: the worst of the metrics. Older reports have none.
  final String severity;
  final ReportEscalation? escalation;

  /// True when the backend fell back to deterministic prose — worth surfacing
  /// quietly rather than pretending the report is complete.
  final bool narrationIncomplete;

  /// Builds a report from a `predictions` row. Returns null for other kinds.
  static ActivityReport? fromRow(Map<String, dynamic> row) {
    if (row['kind'] != 'activity_summary') return null;
    var analysis = row['analysis'];
    // A REST read decodes jsonb into a Map; a Realtime payload can deliver it as a
    // JSON string. Accept both rather than silently dropping the report.
    if (analysis is String) {
      try {
        analysis = jsonDecode(analysis);
      } catch (_) {
        return null;
      }
    }
    if (analysis is! Map) return null;
    final json = Map<String, dynamic>.from(analysis);

    final sections = <ReportSection>[];
    for (final raw in (json['sections'] as List? ?? const [])) {
      if (raw is Map) sections.add(ReportSection.fromJson(Map<String, dynamic>.from(raw)));
    }
    final metrics = <ReportMetric>[];
    for (final raw in (json['metrics'] as List? ?? const [])) {
      if (raw is Map) {
        final metric = ReportMetric.fromJson(Map<String, dynamic>.from(raw));
        if (metric != null) metrics.add(metric);
      }
    }
    final flags = (row['guardrail_flags'] as List? ?? const [])
        .map((f) => f.toString())
        .toList();
    final history = json['history_used'];

    return ActivityReport(
      sessionId: (row['event_id'] as String?) ?? '',
      eventType: (json['event_type'] as String?) ?? '',
      headline: ((json['headline'] as String?) ?? (row['summary'] as String?) ?? '').trim(),
      sections: sections.where((s) => s.body.isNotEmpty).toList(),
      metrics: metrics,
      dataQuality: (json['data_quality'] as String?) ?? 'none',
      sessionsCompared: history is Map
          ? ((history['sessions_compared'] as num?)?.round() ?? 0)
          : 0,
      score: ReportScore.fromJson(
        json['score'] is Map ? Map<String, dynamic>.from(json['score'] as Map) : null,
      ),
      narrationIncomplete: flags.contains('narration_incomplete'),
      severity: (json['severity'] as String?) ?? 'normal',
      escalation: ReportEscalation.fromJson(
        json['escalation'] is Map
            ? Map<String, dynamic>.from(json['escalation'] as Map)
            : null,
      ),
    );
  }
}
