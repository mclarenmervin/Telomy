import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/core/auth/supabase_token_storage.dart';

/// Getting the signed-in user's token to our own API.
///
/// The app signs in through Supabase, which keeps the session in its own
/// client. `ApiClient`'s interceptor reads `TokenStorage`, which only
/// `ApiAuthRepository` and `MockAuthRepository` ever wrote to — so with Supabase
/// auth configured, every request to our gateway went out with **no
/// Authorization header** and came back 401.
///
/// Nothing caught it because the one endpoint the app calls over REST is lab
/// confirmation, which has never run on a device. It is the whole reason this
/// adapter exists: the session Supabase already holds *is* the credential.

class FakeSession {
  FakeSession(this.accessToken, this.refreshToken);
  final String accessToken;
  final String? refreshToken;
}

void main() {
  test('it returns the live Supabase access token', () async {
    final storage = SupabaseTokenStorage(
      session: () => FakeSession('jwt-abc', 'refresh-xyz'),
    );

    expect(await storage.readAccessToken(), 'jwt-abc');
    expect(await storage.readRefreshToken(), 'refresh-xyz');
  });

  test('it reads the session each time rather than caching it', () async {
    // Supabase rotates the access token on refresh. A cached copy would start
    // failing an hour after sign-in, which is the worst kind of bug to chase.
    var token = 'first';
    final storage = SupabaseTokenStorage(session: () => FakeSession(token, null));

    expect(await storage.readAccessToken(), 'first');
    token = 'rotated';
    expect(await storage.readAccessToken(), 'rotated');
  });

  test('no session means no token rather than an error', () async {
    final storage = SupabaseTokenStorage(session: () => null);

    expect(await storage.readAccessToken(), isNull);
  });

  test('a throwing session lookup is treated as signed out', () async {
    // Supabase.instance throws if it has not been initialised. A screen that
    // builds before init must not crash the app.
    final storage = SupabaseTokenStorage(session: () => throw StateError('not ready'));

    expect(await storage.readAccessToken(), isNull);
  });

  test('saving and clearing are no-ops it does not pretend to support',
      () async {
    // Supabase owns the session. Writing here would create a second, divergent
    // copy of the truth, which is the defect this adapter exists to remove.
    final storage = SupabaseTokenStorage(session: () => FakeSession('jwt', null));

    await storage.save(accessToken: 'ignored');
    await storage.clear();

    expect(await storage.readAccessToken(), 'jwt');
  });
}
