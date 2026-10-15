class TherapySession {
  const TherapySession({
    required this.id, required this.status, required this.prescribedDose,
    this.deliveredDose, this.scheduledStart, this.startedAt, this.endedAt,
  });
  final String id, status;
  final Map<String, dynamic> prescribedDose;
  final Map<String, dynamic>? deliveredDose;
  final DateTime? scheduledStart, startedAt, endedAt;

  factory TherapySession.fromJson(Map<String, dynamic> json) => TherapySession(
    id: json['id']?.toString() ?? '', status: json['status']?.toString() ?? 'scheduled',
    prescribedDose: (json['prescribed_dose'] as Map?)?.cast<String, dynamic>() ?? const {},
    deliveredDose: (json['delivered_dose'] as Map?)?.cast<String, dynamic>(),
    scheduledStart: DateTime.tryParse(json['scheduled_start']?.toString() ?? ''),
    startedAt: DateTime.tryParse(json['started_at']?.toString() ?? ''),
    endedAt: DateTime.tryParse(json['ended_at']?.toString() ?? ''),
  );
}

String therapyDoseText(Map<String, dynamic>? dose) {
  if (dose == null || dose.isEmpty) return 'Not recorded';
  if (dose['duration_minutes'] != null) return '${dose['duration_minutes']} minutes';
  return dose.entries.map((entry) => '${entry.key}: ${entry.value}').join(', ');
}
