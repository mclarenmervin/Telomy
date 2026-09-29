import 'package:dio/dio.dart';
import '../auth/token_storage.dart';
import 'api_endpoints.dart';

class ApiClient {
  ApiClient(
    ApiConfig config,
    TokenStorage tokens, {
    required Future<void> Function() onUnauthorized,
  }) {
    dio = Dio(
      BaseOptions(
        baseUrl: config.baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          try {
            if (options.extra['public'] != true) {
              final token = await tokens.readAccessToken();
              if (token != null) {
                options.headers['Authorization'] = 'Bearer $token';
              }
            }
            handler.next(options);
          } catch (_) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.unknown,
              ),
            );
          }
        },
        onError: (error, handler) async {
          if (error.response?.statusCode == 401 &&
              error.requestOptions.extra['public'] != true) {
            try {
              await onUnauthorized();
            } catch (_) {
              /* Preserve the original HTTP error. */
            }
          }
          handler.next(error);
        },
      ),
    );
  }
  late final Dio dio;
}
