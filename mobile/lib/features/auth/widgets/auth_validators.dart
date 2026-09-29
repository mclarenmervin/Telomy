abstract final class AuthValidators {
  static String? email(String? value) =>
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value?.trim() ?? '')
      ? null
      : 'Enter a valid email address';
  static String? password(String? value) =>
      (value?.length ?? 0) >= 8 ? null : 'Use at least 8 characters';
  static String? name(String? value) =>
      (value?.trim().length ?? 0) >= 2 ? null : 'Enter your full name';
  static String? phone(String? value) =>
      RegExp(r'^\+?[\d\s()\-]{7,20}$').hasMatch(value?.trim() ?? '') &&
          (value?.replaceAll(RegExp(r'\D'), '').length ?? 0) >= 7
      ? null
      : 'Enter a valid phone number';
}
