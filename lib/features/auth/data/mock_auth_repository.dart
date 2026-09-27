import '../../../core/auth/token_storage.dart';
import '../models/app_user.dart';
import 'auth_repository.dart';

/// A demo session marker, never a JWT or proof of server authentication.
class MockAuthRepository implements AuthRepository {
  MockAuthRepository(this.tokens);
  final TokenStorage tokens;
  static const demo = AppUser(
    id: '00000000-0000-4000-8000-000000000001',
    fullName: 'Alex Morgan',
    email: 'alex@example.com',
  );
  @override
  Future<AppUser?> restoreSession() async =>
      await tokens.readAccessToken() == 'telomy-demo-session' ? demo : null;
  @override
  Future<AppUser> login(String email, String password) async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    await tokens.save(accessToken: 'telomy-demo-session');
    return demo;
  }

  @override
  Future<AppUser> signup({
    required String fullName,
    required String email,
    required String phone,
    required String password,
  }) => login(email, password);
  @override
  Future<void> forgotPassword(String email) async =>
      Future<void>.delayed(const Duration(milliseconds: 350));
  @override
  Future<void> deleteAccount() => tokens.clear();
  @override
  Future<void> logout() => tokens.clear();
}
