class CareDoctor {
  const CareDoctor({
    required this.id,
    required this.name,
    this.isPrimary = false,
  });

  factory CareDoctor.fromJson(Map<String, dynamic> json) => CareDoctor(
    id: json['id'].toString(),
    name: json['name']?.toString() ?? 'Doctor',
    isPrimary: json['is_primary'] == true,
  );

  final String id;
  final String name;
  final bool isPrimary;
}

class PatientCentre {
  const PatientCentre({
    required this.id,
    required this.name,
    required this.doctors,
    required this.consentActive,
    this.consentExpiresAt,
    this.consentHistory = const [],
  });

  factory PatientCentre.fromJson(Map<String, dynamic> json) {
    final consent =
        (json['consent'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PatientCentre(
      id: json['id'].toString(),
      name: json['name']?.toString() ?? 'Centre',
      doctors: [
        for (final row in json['doctors'] as List? ?? const [])
          CareDoctor.fromJson((row as Map).cast<String, dynamic>()),
      ],
      consentActive: consent['active'] == true,
      consentExpiresAt: DateTime.tryParse(
        consent['expires_at']?.toString() ?? '',
      )?.toUtc(),
      consentHistory: [
        for (final row in consent['history'] as List? ?? const [])
          (row as Map).cast<String, dynamic>(),
      ],
    );
  }

  final String id;
  final String name;
  final List<CareDoctor> doctors;
  final bool consentActive;
  final DateTime? consentExpiresAt;
  final List<Map<String, dynamic>> consentHistory;

  bool get consentExpired =>
      !consentActive &&
      consentExpiresAt != null &&
      !consentExpiresAt!.isAfter(DateTime.now().toUtc());
}

class PatientCare {
  const PatientCare(this.centres);

  factory PatientCare.fromJson(Map<String, dynamic> json) => PatientCare([
    for (final row in json['centres'] as List? ?? const [])
      PatientCentre.fromJson((row as Map).cast<String, dynamic>()),
  ]);

  final List<PatientCentre> centres;
}
