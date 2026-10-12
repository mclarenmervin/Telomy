import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/environment/data/coarse_places.dart';
import 'package:telomy/features/environment/data/environment_repository.dart';
import 'package:telomy/features/environment/providers/environment_provider.dart';

/// Where somebody says they are, and what we look up for them.
///
/// The interesting assertions are the privacy ones: that nothing more
/// precise than a city ever exists on the device, and that the profile keys
/// the app writes are the ones the server reads. The second of those is the
/// bug F9 found in the server gate from the other side.

class StubAdapter implements HttpClientAdapter {
  StubAdapter({this.status = 200, Map<String, dynamic>? body})
      : body = body ?? {'status': 'empty', 'items': []};

  int status;
  Map<String, dynamic> body;
  RequestOptions? lastRequest;
  DioExceptionType? throws;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    if (throws != null) {
      throw DioException(requestOptions: options, type: throws!);
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> day({
  double? aqiMax = 181,
  String? aqiBand = 'unhealthy',
  double? uv = 9.4,
  String? uvBand = 'very high',
  int hours = 24,
}) =>
    {
      'observed_on': '2026-10-11',
      'us_aqi_mean': 92.0,
      'us_aqi_max': aqiMax,
      'us_aqi_band': aqiBand,
      'pm2_5_mean': 40.0,
      'uv_index_max': uv,
      'uv_band': uvBand,
      'hours_observed': hours,
      'provider': 'open-meteo',
    };

EnvironmentRepository repositoryWith(StubAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000'));
  dio.httpClientAdapter = adapter;
  return EnvironmentRepository(http: dio);
}

void main() {
  group('the places on offer', () {
    test('every coordinate is already a city and not a street', () {
      // One decimal place is the whole privacy argument. A list entry with
      // more precision than the server would keep is a list entry that
      // leaked something for no reason.
      for (final place in coarsePlaces) {
        expect(
          place.latitude,
          place.latitude.toStringAsFixed(1).let(double.parse),
          reason: place.label,
        );
        expect(
          place.longitude,
          place.longitude.toStringAsFixed(1).let(double.parse),
          reason: place.label,
        );
      }
    });

    test('coordinates are on the planet', () {
      for (final place in coarsePlaces) {
        expect(place.latitude, inInclusiveRange(-90, 90), reason: place.label);
        expect(place.longitude, inInclusiveRange(-180, 180), reason: place.label);
      }
    });

    test('no two places share a cell, or one of them is unreachable', () {
      final cells = <String>{};
      for (final place in coarsePlaces) {
        final cell = '${place.latitude},${place.longitude}';
        expect(cells.add(cell), isTrue, reason: '${place.label} duplicates $cell');
      }
    });

    test('searching matches a name or a region', () {
      expect(searchPlaces('bengal').map((p) => p.name), contains('Bengaluru'));
      expect(searchPlaces('kerala').map((p) => p.name), contains('Kochi'));
      expect(searchPlaces('  MUMBAI ').single.name, 'Mumbai');
    });

    test('an empty search is the whole list rather than nothing', () {
      expect(searchPlaces('').length, coarsePlaces.length);
    });

    test('a stored coordinate finds its way back to a place', () {
      // Matched on the coordinate and not a stored name: the coordinate is
      // the fact, the name is a label, and renaming a city must not orphan
      // somebody's setting.
      expect(placeAt(13.0, 77.6)?.name, 'Bengaluru');
      expect(placeAt(null, null), isNull);
      expect(placeAt(0.0, 0.0), isNull);
    });
  });

  group('the profile keys', () {
    test('are the ones the server reads', () {
      // app/analytics/environment.py looks for exactly these. A typo is a
      // feature that silently never runs, which is how the server gate's
      // own mismatch went unnoticed until somebody wrote this half.
      expect(consentLocationKey, 'consentLocation');
      expect(coarseLatitudeKey, 'coarseLatitude');
      expect(coarseLongitudeKey, 'coarseLongitude');
    });

    test('and yes is the string every other consent in the app uses', () {
      expect(consentYes, 'true');
    });
  });

  group('reading the days', () {
    test('a day comes back with its bands and its provider', () async {
      final adapter = StubAdapter(body: {'status': 'ok', 'items': [day()]});

      final days = await repositoryWith(adapter).recent();

      expect(adapter.lastRequest!.path, '/api/v1/environment');
      expect(days.single.usAqiMax, 181);
      expect(days.single.usAqiBand, 'unhealthy');
      expect(days.single.provider, 'open-meteo');
    });

    test('no location is an empty list and not an error', () async {
      final days = await repositoryWith(StubAdapter()).recent();

      expect(days, isEmpty);
    });

    test('a partial day knows it is one', () async {
      final adapter = StubAdapter(
        body: {'status': 'ok', 'items': [day(hours: 4)]},
      );

      final days = await repositoryWith(adapter).recent();

      expect(days.single.isPartialDay, isTrue);
    });

    test('a full day is not flagged as partial', () async {
      final adapter = StubAdapter(body: {'status': 'ok', 'items': [day()]});

      expect((await repositoryWith(adapter).recent()).single.isPartialDay, isFalse);
    });

    test('a missing reading stays missing rather than becoming zero', () async {
      final adapter = StubAdapter(
        body: {
          'status': 'ok',
          'items': [day(uv: null, uvBand: null)],
        },
      );

      final days = await repositoryWith(adapter).recent();

      expect(days.single.uvIndexMax, isNull);
      expect(days.single.uvBand, isNull);
    });

    test('offline says so rather than showing clean air', () async {
      final adapter = StubAdapter()..throws = DioExceptionType.connectionError;

      await expectLater(
        repositoryWith(adapter).recent(),
        throwsA(isA<EnvironmentUnavailable>()),
      );
    });

    test('a build with no service configured says so', () async {
      await expectLater(
        EnvironmentRepository().recent(),
        throwsA(isA<EnvironmentUnavailable>()),
      );
    });
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
