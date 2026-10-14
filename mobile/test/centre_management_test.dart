import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/app/role_routes.dart';
import 'package:telomy/features/centre/data/centre_repository.dart';
import 'package:telomy/features/centre/models/centre_operations.dart';
import 'package:telomy/features/centre/providers/centre_provider.dart';
import 'package:telomy/features/roles/models/app_role.dart';

class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.handler);
  final ResponseBody Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);
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
    'mine returns membership identity and operations use only its header',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost'))
        ..httpClientAdapter = StubAdapter((options) {
          requests.add(options);
          if (options.path.endsWith('/mine')) {
            return response({
              'items': [
                {
                  'id': 'centre-a',
                  'membership_id': 'membership-a',
                  'name': 'North Centre',
                  'timezone_name': 'Asia/Kolkata',
                  'currency_code': 'INR',
                },
              ],
            });
          }
          if (options.method == 'GET') {
            if (options.path.endsWith('/dashboard')) {
              return response(dashboardJson('centre-a'));
            }
            return response({
              'items': [],
              'room_hours': [],
              'compatibility': [],
            });
          }
          return response({'id': 'created'}, status: 201);
        });
      final repo = CentreRepository(http: dio);
      final mine = await repo.mine();
      expect(mine.single.membershipId, 'membership-a');

      const membership = 'membership-a';
      await repo.dashboard(membership);
      await repo.doctors(membership);
      await repo.members(membership);
      await repo.rooms(membership);
      await repo.services(membership);
      await repo.bookings(membership);
      await repo.invite(
        membershipId: membership,
        email: 'doctor@example.com',
        role: 'doctor',
      );
      await repo.assign(
        membershipId: membership,
        patientId: 'p1',
        doctorId: 'd1',
        primary: true,
      );
      await repo.setPrimary(
        membershipId: membership,
        patientId: 'p1',
        doctorId: 'd2',
      );
      await repo.endAssignment(
        membershipId: membership,
        patientId: 'p1',
        assignmentId: 'a1',
      );
      await repo.createRoom(membership, name: 'Room A');
      await repo.setRoomStatus(membership, roomId: 'r1', status: 'inactive');
      await repo.addRoomHours(
        membership,
        roomId: 'r1',
        weekday: 1,
        opensAt: '09:00',
        closesAt: '17:00',
        validFrom: '2026-10-01',
      );
      await repo.createService(
        membership,
        name: 'Review',
        durationMinutes: 30,
        indicativePriceMinor: 150000,
        currencyCode: 'INR',
      );
      await repo.setServiceStatus(
        membership,
        serviceId: 's1',
        status: 'inactive',
      );
      await repo.linkRoomService(membership, serviceId: 's1', roomId: 'r1');
      await repo.createBooking(
        membership,
        patientId: 'p1',
        serviceId: 's1',
        roomId: 'r1',
        scheduledStart: DateTime.utc(2026, 10, 20, 9),
      );
      await repo.transitionBooking(
        membership,
        bookingId: 'b1',
        command: 'check_in',
        expectedVersion: 0,
      );

      for (final request in requests.skip(1)) {
        expect(request.headers['X-Centre-Membership'], membership);
        expect(request.path, isNot(contains('centre-a')));
        expect(request.path, isNot(contains('membership-a')));
        if (request.data case final Map data) {
          expect(data.containsKey('centre_id'), isFalse);
          expect(data.containsKey('membership_id'), isFalse);
        }
      }
    },
  );

  test('operational payloads parse immutable snapshots and minor units', () {
    final dashboard = CentreDashboard.fromJson(dashboardJson('centre-a'));
    expect(dashboard.indicativeValue.currentMonthMinor, 125000);
    expect(dashboard.indicativeValue.currencyCode, 'INR');
    expect(dashboard.sessions.currentMonth, 3);
    expect(dashboard.members.total, 2);
    expect(dashboard.todayBookings.single.version, 4);
    expect(dashboard.utilisation.single.rate, .5);

    final member = CentreMember.fromJson({
      'id': 'p1',
      'display_name': 'Asha',
      'assignments': [],
      'bookings': [],
      'risk_evidence': [],
    });
    expect(member.displayName, 'Asha');
    final room = CentreRoom.fromJson({
      'id': 'r1',
      'name': 'Room A',
      'status': 'active',
    });
    final hours = CentreRoomHours.fromJson({
      'id': 'h1',
      'room_id': 'r1',
      'weekday': 1,
      'opens_at': '09:00:00',
      'closes_at': '17:00:00',
      'valid_from': '2026-10-01',
    });
    final service = CentreService.fromJson({
      'id': 's1',
      'name': 'Review',
      'duration_minutes': 30,
      'indicative_price_minor': 125000,
      'currency_code': 'INR',
      'status': 'active',
    });
    expect(room.name, 'Room A');
    expect(hours.weekday, 1);
    expect(service.indicativePriceMinor, 125000);
    final transition = CentreBookingTransition.fromJson({
      'id': 't1',
      'booking_id': 'b1',
      'from_status': 'booked',
      'to_status': 'checked_in',
      'command': 'check_in',
      'expected_version': 0,
      'created_at': '2026-10-14T09:00:00Z',
    });
    expect(transition.toStatus, 'checked_in');
    expect(transition.expectedVersion, 0);
  });

  test('409 asks the UI to refresh while 403 and 503 stay honest', () async {
    Future<Object> failure(int status) async {
      final dio = Dio()
        ..httpClientAdapter = StubAdapter(
          (_) => response({'detail': 'x'}, status: status),
        );
      try {
        await CentreRepository(http: dio).bookings('membership-a');
      } catch (error) {
        return error;
      }
      return StateError('expected failure');
    }

    expect(await failure(409), isA<CentreConflict>());
    expect(
      (await failure(403) as CentreUnavailable).message,
      contains('access'),
    );
    expect(
      (await failure(503) as CentreUnavailable).message,
      contains('temporarily'),
    );
  });

  test(
    'switching membership cannot publish a stale prior-centre dashboard',
    () async {
      final repository = DelayedCentreRepository();
      final container = ProviderContainer(
        overrides: [centreRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      container.read(selectedCentreProvider.notifier).select('membership-a');
      final first = container.read(activeCentreDashboardProvider.future);
      container.read(selectedCentreProvider.notifier).select('membership-b');
      final second = container.read(activeCentreDashboardProvider.future);
      repository.complete(
        'membership-a',
        CentreDashboard.fromJson(dashboardJson('centre-a')),
      );
      repository.complete(
        'membership-b',
        CentreDashboard.fromJson(dashboardJson('centre-b')),
      );
      // Riverpod forwards the first listener to the newly selected membership;
      // the late Centre A result is never published into active state.
      expect((await first).centre.id, 'centre-b');
      expect((await second).centre.id, 'centre-b');
      expect(
        container.read(activeCentreDashboardProvider).requireValue.centre.id,
        'centre-b',
      );
    },
  );

  test('centre shell names the five management branches', () {
    expect(roleTabs(AppRole.centre).map((tab) => tab.label), [
      'Dashboard',
      'Doctors',
      'Patients',
      'Assignments',
      'Profile',
    ]);
  });
}

Map<String, dynamic> dashboardJson(String centreId) => {
  'centre': {
    'id': centreId,
    'name': 'North Centre',
    'timezone_name': 'Asia/Kolkata',
    'currency_code': 'INR',
  },
  'periods': {'current_month': '2026-10', 'previous_month': '2026-09'},
  'indicative_booking_value': {
    'currency_code': 'INR',
    'current_month_minor': 125000,
    'previous_month_minor': 80000,
  },
  'sessions': {'current_month': 3, 'previous_month': 2},
  'members': {
    'total': 2,
    'active_30_days': ['p1'],
    'not_seen_30_days': ['p2'],
  },
  'today_bookings': [bookingJson()],
  'no_show': {'numerator': 1, 'denominator': 4, 'rate': .25},
  'utilisation': [
    {
      'service_id': 's1',
      'service_name': 'Review',
      'capacity_minutes': 240,
      'utilised_minutes': 120,
      'rate': .5,
      'inconsistent_over_capacity': false,
    },
  ],
  'members_at_risk': [
    {
      'id': 'p1',
      'display_name': 'Asha',
      'follow_up_recommended': true,
      'evidence_class': 'attention_reading',
      'date': '2026-10-13',
      'action': 'Suggest a doctor consultation or retest.',
    },
  ],
};

Map<String, dynamic> bookingJson() => {
  'id': 'b1',
  'patient_id': 'p1',
  'service_id': 's1',
  'room_id': 'r1',
  'scheduled_start': '2026-10-14T09:00:00Z',
  'scheduled_end': '2026-10-14T09:30:00Z',
  'status': 'checked_in',
  'version': 4,
  'service_name_snapshot': 'Review',
  'duration_minutes_snapshot': 30,
  'indicative_price_minor_snapshot': 125000,
  'currency_code_snapshot': 'INR',
};

class DelayedCentreRepository extends CentreRepository {
  DelayedCentreRepository() : super(http: Dio());
  final pending = <String, Completer<CentreDashboard>>{};
  @override
  Future<CentreDashboard> dashboard(String membershipId) =>
      (pending[membershipId] ??= Completer<CentreDashboard>()).future;
  void complete(String membershipId, CentreDashboard value) =>
      pending[membershipId]!.complete(value);
}
