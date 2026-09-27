import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class TokenStorage {
  Future<String?> readAccessToken();
  Future<String?> readRefreshToken();
  Future<void> save({required String accessToken, String? refreshToken});
  Future<void> clear();
}

class SecureTokenStorage implements TokenStorage {
  SecureTokenStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const _access = 'telomy.access';
  static const _refresh = 'telomy.refresh';
  @override
  Future<String?> readAccessToken() => _storage.read(key: _access);
  @override
  Future<String?> readRefreshToken() => _storage.read(key: _refresh);
  @override
  Future<void> save({required String accessToken, String? refreshToken}) async {
    await _storage.write(key: _access, value: accessToken);
    if (refreshToken != null) {
      await _storage.write(key: _refresh, value: refreshToken);
    } else {
      await _storage.delete(key: _refresh);
    }
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _access);
    await _storage.delete(key: _refresh);
  }
}
