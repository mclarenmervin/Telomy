import '../models/app_user.dart';

abstract interface class AuthRepository {
  Future<AppUser?> restoreSession();
  Future<AppUser> login(String email, String password);
  Future<AppUser> signup({
    required String fullName,
    required String email,
    required String phone,
    required String password,
  });
  Future<void> forgotPassword(String email);
  Future<void> deleteAccount();
  Future<void> logout();
}
