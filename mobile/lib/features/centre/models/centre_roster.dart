class CentreRef {
  const CentreRef({
    required this.id,
    required this.membershipId,
    required this.name,
    this.timezoneName = 'UTC',
    this.currencyCode = 'INR',
  });
  factory CentreRef.fromJson(Map<String, dynamic> json) => CentreRef(
    id: json['id'].toString(),
    membershipId: (json['membership_id'] ?? json['id']).toString(),
    name: json['name']?.toString() ?? 'Centre',
    timezoneName: json['timezone_name']?.toString() ?? 'UTC',
    currencyCode: json['currency_code']?.toString() ?? 'INR',
  );
  final String id;
  final String membershipId;
  final String name;
  final String timezoneName;
  final String currencyCode;
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
      id: (json['user_id'] ?? json['id'] ?? profile['id']).toString(),
      name:
          json['name']?.toString() ??
          profile['full_name']?.toString() ??
          'Person',
      status: json['status']?.toString() ?? 'active',
    );
  }
  final String id;
  final String name;
  final String status;
}
