import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/app_user.dart';
import 'auth_repository.dart';

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this.client);
  final SupabaseClient client;

  @override
  Future<AppUser?> restoreSession() async {
    final user = client.auth.currentUser;
    return user == null ? null : _map(user);
  }

  @override
  Future<AppUser> login(String email, String password) async {
    final response = await client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    if (response.user == null) {
      throw const AuthException('Unable to sign in.');
    }
    return _map(response.user!);
  }

  @override
  Future<AppUser> signup({
    required String fullName,
    required String email,
    required String phone,
    required String password,
  }) async {
    final response = await client.auth.signUp(
      email: email.trim(),
      password: password,
      data: {'full_name': fullName.trim(), 'phone': phone.trim()},
    );
    if (response.user == null) {
      throw const AuthException('Unable to create your account.');
    }
    if (response.session == null) {
      throw const AuthException(
        'Account created. Confirm your email, then sign in.',
      );
    }
    return _map(response.user!);
  }

  @override
  Future<void> forgotPassword(String email) =>
      client.auth.resetPasswordForEmail(email.trim());

  @override
  Future<void> deleteAccount() async {
    await client.rpc<void>('delete_own_account');
    await client.auth.signOut();
  }

  @override
  Future<void> logout() => client.auth.signOut();

  AppUser _map(User user) => AppUser(
    id: user.id,
    fullName:
        (user.userMetadata?['full_name'] as String?)?.trim().isNotEmpty == true
        ? user.userMetadata!['full_name'] as String
        : user.email?.split('@').first ?? 'Telomy user',
    email: user.email ?? '',
  );
}
