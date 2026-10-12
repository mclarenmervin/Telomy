class DoctorCentre {
  const DoctorCentre({required this.id, required this.name});
  factory DoctorCentre.fromJson(Map<String, dynamic> j) => DoctorCentre(
    id: j['id'].toString(),
    name: j['name']?.toString() ?? 'Centre',
  );
  final String id, name;
}

class DoctorPatient {
  const DoctorPatient({
    required this.id,
    required this.name,
    this.assignment = const {},
  });
  factory DoctorPatient.fromJson(Map<String, dynamic> j) => DoctorPatient(
    id: j['id'].toString(),
    name: j['full_name']?.toString() ?? 'Patient',
    assignment: (j['assignment'] as Map?)?.cast<String, dynamic>() ?? const {},
  );
  final String id, name;
  final Map<String, dynamic> assignment;
}

class DoctorToday {
  const DoctorToday({
    required this.patientCount,
    required this.pendingWork,
    required this.criticalEscalations,
  });
  factory DoctorToday.fromJson(Map<String, dynamic> j) => DoctorToday(
    patientCount: (j['patient_count'] as num?)?.toInt() ?? 0,
    pendingWork: (j['pending_work'] as num?)?.toInt() ?? 0,
    criticalEscalations: List<Map<String, dynamic>>.from(
      (j['critical_escalations'] as List? ?? []).map(
        (e) => (e as Map).cast<String, dynamic>(),
      ),
    ),
  );
  final int patientCount, pendingWork;
  final List<Map<String, dynamic>> criticalEscalations;
}

class DoctorWorkQueue {
  const DoctorWorkQueue(this.segments);
  factory DoctorWorkQueue.fromJson(Map<String, dynamic> j) => DoctorWorkQueue({
    for (final key in const [
      'monthly_reports',
      'sync_drafts',
      'consults',
      'therapy_plans',
      'rx_supplements',
    ])
      key: List<Map<String, dynamic>>.from(
        (j[key] as List? ?? []).map((e) => (e as Map).cast<String, dynamic>()),
      ),
  });
  final Map<String, List<Map<String, dynamic>>> segments;
}

class DoctorPatientKey {
  const DoctorPatientKey(this.centreId, this.patientId);
  final String centreId, patientId;
  @override
  bool operator ==(Object other) =>
      other is DoctorPatientKey &&
      other.centreId == centreId &&
      other.patientId == patientId;
  @override
  int get hashCode => Object.hash(centreId, patientId);
}
