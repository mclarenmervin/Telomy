import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/doctor/data/doctor_repository.dart';

class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.handler);
  final ResponseBody Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? s,
    Future<void>? c,
  ) async => handler(o);
  @override
  void close({bool force = false}) {}
}

ResponseBody response(Object value, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(value),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
void main() {
  test(
    'doctor contracts are centre scoped and parse five queue segments',
    () async {
      final paths = <String>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost'))
        ..httpClientAdapter = StubAdapter((o) {
          paths.add('${o.method} ${o.path}');
          if (o.path.endsWith('/centres')) {
            return response({
              'items': [
                {'id': 'a', 'name': 'A'},
              ],
            });
          }
          if (o.path.endsWith('/patients')) {
            return response({
              'items': [
                {
                  'id': o.path.contains('/a/') ? 'pa' : 'pb',
                  'full_name': 'Patient',
                },
              ],
            });
          }
          if (o.path.endsWith('/work-queue')) {
            return response({
              'monthly_reports': [],
              'sync_drafts': [],
              'consults': [],
              'therapy_plans': [],
              'rx_supplements': [],
            });
          }
          return response({});
        });
      final repo = DoctorRepository(http: dio);
      expect((await repo.centres()).single.id, 'a');
      expect((await repo.patients('a')).single.id, 'pa');
      expect((await repo.patients('b')).single.id, 'pb');
      expect((await repo.workQueue('a')).segments.length, 5);
      expect(paths, contains('GET /api/v1/doctor/a/patients'));
    },
  );
  test('blank clinical decision note is rejected before network', () async {
    var calls = 0;
    final dio = Dio()
      ..httpClientAdapter = StubAdapter((_) {
        calls++;
        return response({});
      });
    final repo = DoctorRepository(http: dio);
    await expectLater(
      repo.signDraft(centreId: 'c', draftId: 'd', note: '   ', version: 'v1'),
      throwsArgumentError,
    );
    expect(calls, 0);
  });
  test('server failures map to a safe doctor error', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost'))
      ..httpClientAdapter = StubAdapter(
        (_) => response({'detail': 'secret sql'}, status: 500),
      );
    await expectLater(
      DoctorRepository(http: dio).patients('c'),
      throwsA(
        isA<DoctorUnavailable>().having(
          (e) => e.message,
          'message',
          isNot(contains('sql')),
        ),
      ),
    );
  });
}
