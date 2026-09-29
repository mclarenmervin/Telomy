enum AppEnvironment { development, staging, production }

class ApiConfig {
  ApiConfig({
    required this.environment,
    required this.baseUrl,
    required this.useMocks,
  }) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        !uri.hasAuthority ||
        !['http', 'https'].contains(uri.scheme)) {
      throw ArgumentError('API_BASE_URL must be an absolute HTTP(S) URL.');
    }
    if (environment != AppEnvironment.development && uri.scheme != 'https') {
      throw ArgumentError('Staging and production require HTTPS.');
    }
  }
  factory ApiConfig.fromEnvironment() {
    const name = String.fromEnvironment('APP_ENV', defaultValue: 'development');
    return ApiConfig(
      environment: AppEnvironment.values.byName(name),
      baseUrl: const String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: 'http://localhost:8000',
      ),
      useMocks: const bool.fromEnvironment('USE_MOCKS', defaultValue: true),
    );
  }
  final AppEnvironment environment;
  final String baseUrl;
  final bool useMocks;
}

abstract final class ApiEndpoints {
  static const login = '/auth/login';
  static const register = '/auth/register';
  static const refresh = '/auth/refresh';
  static const forgotPassword = '/auth/forgot-password';
  static const me = '/users/me';
  static const measurements = '/health/measurements';
  static const events = '/events';
  static const therapies = '/therapies';
  static const environment = '/environment';
  static const genetics = '/genetics';
  static const reports = '/reports';
  static const aiChat = '/ai/chat';
}
