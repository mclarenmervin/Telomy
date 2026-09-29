import 'package:dio/dio.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/auth/token_storage.dart';
import '../models/app_user.dart';
import 'auth_repository.dart';

/// Provisional JSON contract; match this adapter to the FastAPI schema.
class ApiAuthRepository implements AuthRepository {
  ApiAuthRepository(this.client, this.tokens);
  final ApiClient client;
  final TokenStorage tokens;
  @override
  Future<AppUser?> restoreSession() async {
    final token = await tokens.readAccessToken();
    if (token == null) return null;
    if (token == 'telomy-demo-session') {
      await tokens.clear();
      return null;
    }
    try {
      final response = await client.dio.get<Map<String, dynamic>>(
        ApiEndpoints.me,
      );
      return AppUser.fromJson(response.data!);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await tokens.clear();
        return null;
      }
      rethrow;
    }
  }

  Future<AppUser> _authenticate(String path, Map<String, dynamic> data) async {
    final response = await client.dio.post<Map<String, dynamic>>(
      path,
      data: data,
      options: Options(extra: {'public': true}),
    );
    final body = response.data!;
    final user = AppUser.fromJson(body['user'] as Map<String, dynamic>);
    await tokens.save(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String?,
    );
    return user;
  }

  @override
  Future<AppUser> login(String email, String password) =>
      _authenticate(ApiEndpoints.login, {'email': email, 'password': password});
  @override
  Future<AppUser> signup({
    required String fullName,
    required String email,
    required String phone,
    required String password,
  }) => _authenticate(ApiEndpoints.register, {
    'full_name': fullName,
    'email': email,
    'phone': phone,
    'password': password,
  });
  @override
  Future<void> forgotPassword(String email) async {
    await client.dio.post<void>(
      ApiEndpoints.forgotPassword,
      data: {'email': email},
      options: Options(extra: {'public': true}),
    );
  }

  @override
  Future<void> deleteAccount() async {
    await client.dio.delete<void>(ApiEndpoints.me);
    await tokens.clear();
  }

  @override
  Future<void> logout() => tokens.clear();
}
