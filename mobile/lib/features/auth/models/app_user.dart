class AppUser {
  const AppUser({
    required this.id,
    required this.fullName,
    required this.email,
  });
  final String id;
  final String fullName;
  final String email;
  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    id: json['id'] as String,
    fullName: json['full_name'] as String,
    email: json['email'] as String,
  );
}
