import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/core/api/api_endpoints.dart';

void main() {
  test('production refuses cleartext URLs', () {
    expect(
      () => ApiConfig(
        environment: AppEnvironment.production,
        baseUrl: 'http://example.com',
        useMocks: false,
      ),
      throwsArgumentError,
    );
  });
  test('development accepts a local API', () {
    final config = ApiConfig(
      environment: AppEnvironment.development,
      baseUrl: 'http://localhost:8000',
      useMocks: true,
    );
    expect(config.useMocks, isTrue);
  });
}
