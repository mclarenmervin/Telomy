import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/auth/supabase_token_storage.dart';
import '../../../core/auth/token_storage.dart';
import '../data/auth_repository.dart';
import '../data/api_auth_repository.dart';
import '../data/mock_auth_repository.dart';
import '../data/supabase_auth_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/config/supabase_config.dart';
import '../models/app_user.dart';

final apiConfigProvider = Provider((ref) => ApiConfig.fromEnvironment());
/// Where ApiClient gets its bearer token.
///
/// With Supabase auth configured the session lives in the Supabase client, and
/// nothing ever wrote it into secure storage -- so every call to our own
/// gateway went out unauthenticated and came back 401. Reading the live session
/// keeps one copy of the credential instead of two that can diverge.
final tokenStorageProvider = Provider<TokenStorage>(
  (ref) => SupabaseConfig.configured ? SupabaseTokenStorage() : SecureTokenStorage(),
);
final apiClientProvider = Provider((ref) {
  final tokens = ref.watch(tokenStorageProvider);
  final client = ApiClient(
    ref.watch(apiConfigProvider),
    tokens,
    onUnauthorized: () async {
      ref.read(authProvider.notifier).expireSession();
      await tokens.clear();
    },
  );
  ref.onDispose(() => client.dio.close());
  return client;
});
final authRepositoryProvider = Provider<AuthRepository>((ref) {
  if (SupabaseConfig.configured) {
    return SupabaseAuthRepository(Supabase.instance.client);
  }
  final tokens = ref.watch(tokenStorageProvider);
  return ref.watch(apiConfigProvider).useMocks
      ? MockAuthRepository(tokens)
      : ApiAuthRepository(ref.watch(apiClientProvider), tokens);
});
final authProvider = AsyncNotifierProvider<AuthController, AppUser?>(
  AuthController.new,
);

class AuthController extends AsyncNotifier<AppUser?> {
  @override
  Future<AppUser?> build() async {
    if (SupabaseConfig.configured) {
      final subscription = Supabase.instance.client.auth.onAuthStateChange
          .listen((event) {
            if (!ref.mounted) return;
            final user = event.session?.user;
            if (user == null) {
              state = const AsyncData(null);
            } else {
              final metadata = user.userMetadata;
              state = AsyncData(
                AppUser(
                  id: user.id,
                  fullName:
                      metadata?['full_name'] as String? ??
                      user.email?.split('@').first ??
                      'Telomy user',
                  email: user.email ?? '',
                ),
              );
            }
          });
      ref.onDispose(subscription.cancel);
    }
    return ref.watch(authRepositoryProvider).restoreSession();
  }

  Future<void> login(String email, String password) =>
      _run(() => ref.read(authRepositoryProvider).login(email, password));
  Future<void> signup({
    required String fullName,
    required String email,
    required String phone,
    required String password,
  }) => _run(
    () => ref
        .read(authRepositoryProvider)
        .signup(
          fullName: fullName,
          email: email,
          phone: phone,
          password: password,
        ),
  );
  Future<void> _run(Future<AppUser> Function() action) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(action);
  }

  void expireSession() => state = const AsyncData(null);
  Future<void> deleteAccount() async {
    await ref.read(authRepositoryProvider).deleteAccount();
    state = const AsyncData(null);
  }

  Future<void> logout() async {
    await ref.read(authRepositoryProvider).logout();
    state = const AsyncData(null);
  }
}
