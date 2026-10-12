import '../../roles/models/app_role.dart';

enum InvitationStatus { pending, accepted, declined, expired, revoked }

class AccountInvitation {
  const AccountInvitation({
    required this.id,
    required this.email,
    required this.role,
    this.centreId,
    required this.status,
    this.requiresVerification = false,
    this.expiresAt,
  });
  factory AccountInvitation.fromJson(Map<String, dynamic> json) {
    final rawStatus = json['status']?.toString() ?? 'pending';
    return AccountInvitation(
      id: (json['invitation_id'] ?? json['id']).toString(),
      email: json['email']?.toString() ?? '',
      role: AppRole.parse(json['intended_role']?.toString()),
      centreId: json['centre_id']?.toString(),
      status: InvitationStatus.values.firstWhere(
        (value) => value.name == rawStatus,
        orElse: () => InvitationStatus.pending,
      ),
      requiresVerification: json['requires_verification'] == true,
      expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
    );
  }
  final String id;
  final String email;
  final AppRole role;
  final String? centreId;
  final InvitationStatus status;
  final bool requiresVerification;
  final DateTime? expiresAt;
  bool get actionable =>
      status == InvitationStatus.pending &&
      (expiresAt == null || expiresAt!.isAfter(DateTime.now()));
}
