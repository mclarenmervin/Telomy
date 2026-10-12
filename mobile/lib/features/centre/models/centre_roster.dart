class CentreRef {
  const CentreRef({required this.id, required this.name});
  factory CentreRef.fromJson(Map<String, dynamic> json) => CentreRef(
    id: json['id'].toString(),
    name: json['name']?.toString() ?? 'Centre',
  );
  final String id;
  final String name;
}

class CentrePerson {
  const CentrePerson({
    required this.id,
    required this.name,
    required this.status,
  });
  factory CentrePerson.fromJson(Map<String, dynamic> json) {
    final profile =
        (json['profile'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    return CentrePerson(
      id: (json['user_id'] ?? profile['id']).toString(),
      name: profile['full_name']?.toString() ?? 'Person',
      status: json['status']?.toString() ?? 'active',
    );
  }
  final String id;
  final String name;
  final String status;
}
