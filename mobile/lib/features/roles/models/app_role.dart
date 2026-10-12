/// What this person is on the platform.
///
/// The four names are `profiles.app_role`'s check constraint, and the column
/// is the fact. This enum is a cache of it in exactly the way a JWT claim
/// would be: it decides which screens to draw and it grants nothing. Every
/// read of somebody else's data is refused by RLS (022) and by the gateway
/// (`require_app_role`), independently of anything here.
///
/// NOT `clinic_members.role`, which is membership inside one clinic —
/// patient, clinician, admin — and is what `clinician_may_sign()` reads. One
/// person may be a member of Telomy, a clinician at two clinics and the
/// operator of a centre. `doctor` rather than `clinician` here is what keeps
/// the two axes from sharing a word.
enum AppRole {
  member,
  doctor,
  centre,
  admin;

  /// The role named by a column value, defaulting to the least privileged.
  ///
  /// Three things resolve to [member]: null, empty, and anything this build
  /// does not recognise. The last matters — if the constraint is ever widened
  /// without this enum being updated, an unknown value must not survive as
  /// itself and reach a route table that might admit it. The server makes the
  /// identical coalesce for the identical reason.
  static AppRole parse(String? value) {
    final name = (value ?? '').trim().toLowerCase();
    return AppRole.values.firstWhere(
      (role) => role.name == name,
      orElse: () => AppRole.member,
    );
  }

  /// What this role calls itself on screen.
  String get label => switch (this) {
    AppRole.member => 'Patient',
    AppRole.doctor => 'Doctor',
    AppRole.centre => 'Centre Owner',
    AppRole.admin => 'Super Admin',
  };
}
