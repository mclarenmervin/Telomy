import 'package:supabase_flutter/supabase_flutter.dart';

import 'token_storage.dart';

/// Gives `ApiClient` the token the user is already signed in with.
///
/// The app authenticates through Supabase, which keeps the session inside its
/// own client. `ApiClient`'s interceptor reads `TokenStorage`, and only the
/// legacy `ApiAuthRepository` ever wrote to it — so with Supabase auth
/// configured, every request to our own gateway went out with **no
/// Authorization header** and came back 401.
///
/// Nothing caught it because lab confirmation is the only endpoint the app
/// calls over REST, and it has never run on a device.
///
/// This adapter resolves it by reading the session Supabase already holds
/// rather than keeping a second copy. `save` and `clear` are deliberately
/// no-ops: Supabase owns the session, and a second writable copy of the
/// credential is exactly the divergence this exists to remove.
class SupabaseTokenStorage implements TokenStorage {
  SupabaseTokenStorage({Object? Function()? session}) : _session = session ?? _live;

  final Object? Function() _session;

  static Object? _live() => Supabase.instance.client.auth.currentSession;

  /// Read fresh every time. Supabase rotates the access token on refresh, and a
  /// cached copy would start failing an hour after sign-in — the worst kind of
  /// bug to chase, because it works in every test and in the first few minutes
  /// of every manual check.
  Object? get _current {
    try {
      return _session();
    } catch (_) {
      // Supabase.instance throws before initialisation. A screen that builds
      // early is signed out, not broken.
      return null;
    }
  }

  @override
  Future<String?> readAccessToken() async {
    final session = _current;
    return session == null ? null : (session as dynamic).accessToken as String?;
  }

  @override
  Future<String?> readRefreshToken() async {
    final session = _current;
    return session == null ? null : (session as dynamic).refreshToken as String?;
  }

  @override
  Future<void> save({required String accessToken, String? refreshToken}) async {}

  @override
  Future<void> clear() async {}
}
