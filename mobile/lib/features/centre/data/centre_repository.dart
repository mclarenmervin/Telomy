import 'package:dio/dio.dart';

import '../models/centre_operations.dart';
import '../models/centre_roster.dart';

class CentreUnavailable implements Exception {
  const CentreUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

class CentreConflict extends CentreUnavailable {
  const CentreConflict()
    : super('This centre record changed. Refresh before trying again.');
}

class CentreRepository {
  CentreRepository({required Dio http}) : _http = http;
  final Dio _http;

  Future<List<CentreRef>> mine() async => [
    for (final row in await _items('/api/v1/centre/mine'))
      CentreRef.fromJson(row),
  ];

  Future<CentreDashboard> dashboard(String membershipId) async =>
      CentreDashboard.fromJson(
        _map(
          await _request(
            'GET',
            '/api/v1/centre/dashboard',
            membershipId: membershipId,
          ),
        ),
      );

  Future<List<CentrePerson>> doctors(String membershipId) async => [
    for (final row in await _items(
      '/api/v1/centre/doctors',
      membershipId: membershipId,
    ))
      CentrePerson.fromJson(row),
  ];

  Future<List<CentreMember>> members(String membershipId) async => [
    for (final row in await _items(
      '/api/v1/centre/members',
      membershipId: membershipId,
    ))
      CentreMember.fromJson(row),
  ];

  Future<List<CentreMember>> patients(String membershipId) =>
      members(membershipId);

  Future<CentreRooms> rooms(String membershipId) async {
    final data = _map(
      await _request('GET', '/api/v1/centre/rooms', membershipId: membershipId),
    );
    return CentreRooms(
      items: _maps(
        data['items'],
      ).map(CentreRoom.fromJson).toList(growable: false),
      hours: _maps(
        data['room_hours'],
      ).map(CentreRoomHours.fromJson).toList(growable: false),
    );
  }

  Future<CentreServices> services(String membershipId) async {
    final data = _map(
      await _request(
        'GET',
        '/api/v1/centre/services',
        membershipId: membershipId,
      ),
    );
    return CentreServices(
      items: _maps(
        data['items'],
      ).map(CentreService.fromJson).toList(growable: false),
      compatibility: _maps(
        data['compatibility'],
      ).map(RoomServiceLink.fromJson).toList(growable: false),
    );
  }

  Future<List<CentreBooking>> bookings(
    String membershipId, {
    String? status,
    DateTime? dateFrom,
    DateTime? dateTo,
  }) async => [
    for (final row in await _items(
      '/api/v1/centre/bookings',
      membershipId: membershipId,
      query: {
        'status': ?status,
        if (dateFrom != null) 'date_from': dateFrom.toUtc().toIso8601String(),
        if (dateTo != null) 'date_to': dateTo.toUtc().toIso8601String(),
      },
    ))
      CentreBooking.fromJson(row),
  ];

  Future<void> invite({
    String? membershipId,
    String? centreId,
    required String email,
    required String role,
    String? primaryDoctorId,
  }) async {
    final membership = _membership(membershipId, centreId);
    await _request(
      'POST',
      '/api/v1/centre/invitations',
      membershipId: membership,
      data: {
        'email': email,
        'intended_role': role,
        'primary_doctor_id': primaryDoctorId,
      },
      headers: {
        'Idempotency-Key': '${DateTime.now().microsecondsSinceEpoch}-$email',
      },
    );
  }

  Future<String> assign({
    String? membershipId,
    String? centreId,
    required String patientId,
    required String doctorId,
    bool primary = false,
  }) => _command(
    'POST',
    '/api/v1/centre/patients/$patientId/assignments',
    _membership(membershipId, centreId),
    {'doctor_id': doctorId, 'primary': primary},
  );

  Future<String> setPrimary({
    String? membershipId,
    String? centreId,
    required String patientId,
    required String doctorId,
  }) => _command(
    'PATCH',
    '/api/v1/centre/patients/$patientId/primary-doctor',
    _membership(membershipId, centreId),
    {'doctor_id': doctorId},
  );

  Future<void> endAssignment({
    required String membershipId,
    required String patientId,
    required String assignmentId,
  }) async {
    await _request(
      'DELETE',
      '/api/v1/centre/patients/$patientId/assignments/$assignmentId',
      membershipId: membershipId,
    );
  }

  Future<String> createRoom(String membershipId, {required String name}) =>
      _command('POST', '/api/v1/centre/rooms', membershipId, {'name': name});

  Future<String> setRoomStatus(
    String membershipId, {
    required String roomId,
    required String status,
  }) => _command('PATCH', '/api/v1/centre/rooms/$roomId/status', membershipId, {
    'status': status,
  });

  Future<String> addRoomHours(
    String membershipId, {
    required String roomId,
    required int weekday,
    required String opensAt,
    required String closesAt,
    required String validFrom,
    String? validUntil,
  }) => _command('POST', '/api/v1/centre/rooms/$roomId/hours', membershipId, {
    'weekday': weekday,
    'opens_at': opensAt,
    'closes_at': closesAt,
    'valid_from': validFrom,
    'valid_until': validUntil,
  });

  Future<String> createService(
    String membershipId, {
    required String name,
    String? description,
    required int durationMinutes,
    required int indicativePriceMinor,
    required String currencyCode,
  }) => _command('POST', '/api/v1/centre/services', membershipId, {
    'name': name,
    'description': description,
    'duration_minutes': durationMinutes,
    'indicative_price_minor': indicativePriceMinor,
    'currency_code': currencyCode,
  });

  Future<String> setServiceStatus(
    String membershipId, {
    required String serviceId,
    required String status,
  }) => _command(
    'PATCH',
    '/api/v1/centre/services/$serviceId/status',
    membershipId,
    {'status': status},
  );

  Future<String> linkRoomService(
    String membershipId, {
    required String serviceId,
    required String roomId,
  }) => _command(
    'POST',
    '/api/v1/centre/services/$serviceId/compatible-rooms/$roomId',
    membershipId,
    const {},
  );

  Future<String> createBooking(
    String membershipId, {
    required String patientId,
    required String serviceId,
    required String roomId,
    required DateTime scheduledStart,
  }) => _command('POST', '/api/v1/centre/bookings', membershipId, {
    'patient_id': patientId,
    'service_id': serviceId,
    'room_id': roomId,
    'scheduled_start': scheduledStart.toUtc().toIso8601String(),
  });

  Future<String> transitionBooking(
    String membershipId, {
    required String bookingId,
    required String command,
    required int expectedVersion,
    String? reason,
  }) => _command(
    'POST',
    '/api/v1/centre/bookings/$bookingId/transitions',
    membershipId,
    {'command': command, 'expected_version': expectedVersion, 'reason': reason},
  );

  Future<String> _command(
    String method,
    String path,
    String membershipId,
    Map<String, dynamic> data,
  ) async {
    final result = _map(
      await _request(method, path, membershipId: membershipId, data: data),
    );
    return result['id']?.toString() ?? '';
  }

  Future<List<Map<String, dynamic>>> _items(
    String path, {
    String? membershipId,
    Map<String, dynamic>? query,
  }) async {
    final data = _map(
      await _request('GET', path, membershipId: membershipId, query: query),
    );
    return _maps(data['items']);
  }

  Future<dynamic> _request(
    String method,
    String path, {
    String? membershipId,
    Object? data,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    try {
      final response = await _http.request<dynamic>(
        path,
        data: data,
        queryParameters: query,
        options: Options(
          method: method,
          headers: {'X-Centre-Membership': ?membershipId, ...?headers},
          validateStatus: (status) => status != null && status < 600,
        ),
      );
      switch (response.statusCode ?? 500) {
        case < 400:
          return response.data;
        case 403:
          throw const CentreUnavailable(
            'You no longer have access to this centre.',
          );
        case 409:
          throw const CentreConflict();
        case 503:
          throw const CentreUnavailable(
            'Centre data is temporarily unavailable. Please try again.',
          );
        default:
          throw const CentreUnavailable(
            'This centre action could not be completed.',
          );
      }
    } on CentreUnavailable {
      rethrow;
    } on DioException {
      throw const CentreUnavailable('The centre service is unavailable.');
    }
  }

  String _membership(String? membershipId, String? legacyValue) {
    final value = membershipId ?? legacyValue;
    if (value == null || value.isEmpty) {
      throw ArgumentError('membershipId is required');
    }
    return value;
  }
}

Map<String, dynamic> _map(Object? value) =>
    (value as Map?)?.cast<String, dynamic>() ?? const {};
List<Map<String, dynamic>> _maps(Object? value) => [
  for (final row in value as List? ?? const []) _map(row),
];
