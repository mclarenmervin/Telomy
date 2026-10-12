class CentreSummary {
  const CentreSummary({
    required this.id,
    required this.name,
    required this.status,
  });
  factory CentreSummary.fromJson(Map<String, dynamic> json) => CentreSummary(
    id: json['id'].toString(),
    name: json['name']?.toString() ?? 'Centre',
    status: json['status']?.toString() ?? 'active',
  );
  final String id;
  final String name;
  final String status;
}

class PatientSummary {
  const PatientSummary({
    required this.id,
    required this.name,
    required this.email,
  });
  factory PatientSummary.fromJson(Map<String, dynamic> json) => PatientSummary(
    id: json['id'].toString(),
    name: json['full_name']?.toString() ?? 'Patient',
    email: json['email']?.toString() ?? '',
  );
  final String id;
  final String name;
  final String email;
}
