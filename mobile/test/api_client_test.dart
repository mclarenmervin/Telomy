import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/core/api/api_client.dart';
import 'package:telomy/core/api/api_endpoints.dart';
import 'widget_test.dart' show MemoryTokens;

class StubAdapter implements HttpClientAdapter {
  int status = 200;
  RequestOptions? lastRequest;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      '{}',
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'private requests attach tokens; public requests do not; 401 expires session',
    () async {
      final tokens = MemoryTokens()..access = 'test-token';
      var expired = false;
      final client = ApiClient(
        ApiConfig(
          environment: AppEnvironment.development,
          baseUrl: 'http://localhost:8000',
          useMocks: false,
        ),
        tokens,
        onUnauthorized: () async {
          expired = true;
          await tokens.clear();
        },
      );
      final adapter = StubAdapter();
      client.dio.httpClientAdapter = adapter;
      addTearDown(() => client.dio.close());
      await client.dio.get<void>('/users/me');
      expect(
        adapter.lastRequest!.headers['Authorization'],
        'Bearer test-token',
      );
      await client.dio.post<void>(
        '/auth/login',
        options: Options(extra: {'public': true}),
      );
      expect(
        adapter.lastRequest!.headers.containsKey('Authorization'),
        isFalse,
      );
      adapter.status = 401;
      await expectLater(
        client.dio.get<void>('/users/me'),
        throwsA(isA<DioException>()),
      );
      expect(expired, isTrue);
      expect(tokens.access, isNull);
    },
  );
}
