class CentreIdentity {
  const CentreIdentity({
    required this.id,
    required this.name,
    required this.timezoneName,
    required this.currencyCode,
  });
  factory CentreIdentity.fromJson(Map<String, dynamic> json) => CentreIdentity(
    id: '${json['id']}',
    name: json['name']?.toString() ?? 'Centre',
    timezoneName: json['timezone_name']?.toString() ?? 'UTC',
    currencyCode: json['currency_code']?.toString() ?? 'INR',
  );
  final String id;
  final String name;
  final String timezoneName;
  final String currencyCode;
}

class PeriodComparison {
  const PeriodComparison({
    required this.currentMonth,
    required this.previousMonth,
  });
  factory PeriodComparison.fromJson(Map<String, dynamic> json) =>
      PeriodComparison(
        currentMonth: _integer(json['current_month']),
        previousMonth: _integer(json['previous_month']),
      );
  final int currentMonth;
  final int previousMonth;
}

class IndicativeBookingValue {
  const IndicativeBookingValue({
    required this.currencyCode,
    required this.currentMonthMinor,
    required this.previousMonthMinor,
  });
  factory IndicativeBookingValue.fromJson(Map<String, dynamic> json) =>
      IndicativeBookingValue(
        currencyCode: json['currency_code']?.toString() ?? 'INR',
        currentMonthMinor: _integer(json['current_month_minor']),
        previousMonthMinor: _integer(json['previous_month_minor']),
      );
  final String currencyCode;
  final int currentMonthMinor;
  final int previousMonthMinor;
}

class CentreMemberSummary {
  const CentreMemberSummary({
    required this.total,
    required this.active30Days,
    required this.notSeen30Days,
  });
  factory CentreMemberSummary.fromJson(Map<String, dynamic> json) =>
      CentreMemberSummary(
        total: _integer(json['total']),
        active30Days: _strings(json['active_30_days']),
        notSeen30Days: _strings(json['not_seen_30_days']),
      );
  final int total;
  final List<String> active30Days;
  final List<String> notSeen30Days;
}

class NoShowMetric {
  const NoShowMetric({
    required this.numerator,
    required this.denominator,
    required this.rate,
  });
  factory NoShowMetric.fromJson(Map<String, dynamic> json) => NoShowMetric(
    numerator: _integer(json['numerator']),
    denominator: _integer(json['denominator']),
    rate: _decimal(json['rate']),
  );
  final int numerator;
  final int denominator;
  final double? rate;
}

class CentreBooking {
  const CentreBooking({
    required this.id,
    required this.patientId,
    required this.patientDisplayName,
    required this.serviceId,
    required this.roomId,
    required this.roomName,
    required this.scheduledStart,
    required this.scheduledEnd,
    required this.status,
    required this.version,
    required this.serviceNameSnapshot,
    required this.durationMinutesSnapshot,
    required this.indicativePriceMinorSnapshot,
    required this.currencyCodeSnapshot,
  });
  factory CentreBooking.fromJson(Map<String, dynamic> json) {
    final start = DateTime.parse('${json['scheduled_start']}');
    return CentreBooking(
      id: '${json['id']}',
      patientId: '${json['patient_id']}',
      patientDisplayName: json['patient_display_name']?.toString() ?? 'Member',
      serviceId: '${json['service_id']}',
      roomId: '${json['room_id']}',
      roomName: json['room_name']?.toString() ?? 'Room',
      scheduledStart: start,
      scheduledEnd: json['scheduled_end'] == null
          ? start.add(
              Duration(minutes: _integer(json['duration_minutes_snapshot'])),
            )
          : DateTime.parse('${json['scheduled_end']}'),
      status: json['status']?.toString() ?? 'booked',
      version: _integer(json['version']),
      serviceNameSnapshot:
          json['service_name_snapshot']?.toString() ?? 'Service',
      durationMinutesSnapshot: _integer(json['duration_minutes_snapshot']),
      indicativePriceMinorSnapshot: _integer(
        json['indicative_price_minor_snapshot'],
      ),
      currencyCodeSnapshot: json['currency_code_snapshot']?.toString() ?? 'INR',
    );
  }
  final String id;
  final String patientId;
  final String patientDisplayName;
  final String serviceId;
  final String roomId;
  final String roomName;
  final DateTime scheduledStart;
  final DateTime scheduledEnd;
  final String status;
  final int version;
  final String serviceNameSnapshot;
  final int durationMinutesSnapshot;
  final int indicativePriceMinorSnapshot;
  final String currencyCodeSnapshot;
  bool get isTerminal =>
      const {'completed', 'no_show', 'cancelled'}.contains(status);
}

class CentreBookingTransition {
  const CentreBookingTransition({
    required this.id,
    required this.bookingId,
    required this.fromStatus,
    required this.toStatus,
    required this.command,
    required this.expectedVersion,
    required this.createdAt,
    this.reason,
  });
  factory CentreBookingTransition.fromJson(Map<String, dynamic> json) =>
      CentreBookingTransition(
        id: '${json['id']}',
        bookingId: '${json['booking_id']}',
        fromStatus: json['from_status']?.toString(),
        toStatus: json['to_status']?.toString() ?? 'booked',
        command: json['command']?.toString() ?? 'create',
        expectedVersion: _integer(json['expected_version']),
        reason: json['reason']?.toString(),
        createdAt: DateTime.parse('${json['created_at']}'),
      );
  final String id;
  final String bookingId;
  final String? fromStatus;
  final String toStatus;
  final String command;
  final int expectedVersion;
  final String? reason;
  final DateTime createdAt;
}

class ServiceUtilisation {
  const ServiceUtilisation({
    required this.serviceId,
    required this.serviceName,
    required this.capacityMinutes,
    required this.utilisedMinutes,
    required this.rate,
    required this.inconsistentOverCapacity,
  });
  factory ServiceUtilisation.fromJson(Map<String, dynamic> json) =>
      ServiceUtilisation(
        serviceId: '${json['service_id']}',
        serviceName: json['service_name']?.toString() ?? 'Service',
        capacityMinutes: _integer(json['capacity_minutes']),
        utilisedMinutes: _integer(json['utilised_minutes']),
        rate: _decimal(json['rate']),
        inconsistentOverCapacity: json['inconsistent_over_capacity'] == true,
      );
  final String serviceId;
  final String serviceName;
  final int capacityMinutes;
  final int utilisedMinutes;
  final double? rate;
  final bool inconsistentOverCapacity;
}

class FollowUpMember {
  const FollowUpMember({
    required this.id,
    required this.displayName,
    required this.evidenceClass,
    required this.date,
    required this.action,
  });
  factory FollowUpMember.fromJson(Map<String, dynamic> json) => FollowUpMember(
    id: '${json['id']}',
    displayName: json['display_name']?.toString() ?? 'Member',
    evidenceClass: json['evidence_class']?.toString() ?? 'clinical_follow_up',
    date: json['date']?.toString() ?? '',
    action: json['action']?.toString() ?? '',
  );
  final String id;
  final String displayName;
  final String evidenceClass;
  final String date;
  final String action;
}

class CentreDashboard {
  const CentreDashboard({
    required this.centre,
    required this.indicativeValue,
    required this.sessions,
    required this.members,
    required this.todayBookings,
    required this.noShow,
    required this.utilisation,
    required this.membersAtRisk,
  });
  factory CentreDashboard.fromJson(Map<String, dynamic> json) =>
      CentreDashboard(
        centre: CentreIdentity.fromJson(_map(json['centre'])),
        indicativeValue: IndicativeBookingValue.fromJson(
          _map(json['indicative_booking_value']),
        ),
        sessions: PeriodComparison.fromJson(_map(json['sessions'])),
        members: CentreMemberSummary.fromJson(_map(json['members'])),
        todayBookings: _maps(
          json['today_bookings'],
        ).map(CentreBooking.fromJson).toList(growable: false),
        noShow: NoShowMetric.fromJson(_map(json['no_show'])),
        utilisation: _maps(
          json['utilisation'],
        ).map(ServiceUtilisation.fromJson).toList(growable: false),
        membersAtRisk: _maps(
          json['members_at_risk'],
        ).map(FollowUpMember.fromJson).toList(growable: false),
      );
  final CentreIdentity centre;
  final IndicativeBookingValue indicativeValue;
  final PeriodComparison sessions;
  final CentreMemberSummary members;
  final List<CentreBooking> todayBookings;
  final NoShowMetric noShow;
  final List<ServiceUtilisation> utilisation;
  final List<FollowUpMember> membersAtRisk;
}

class CentreMember {
  const CentreMember({
    required this.id,
    required this.displayName,
    required this.assignments,
    required this.bookings,
    required this.riskEvidence,
  });
  factory CentreMember.fromJson(Map<String, dynamic> json) => CentreMember(
    id: '${json['id']}',
    displayName: json['display_name']?.toString() ?? 'Member',
    assignments: _maps(json['assignments']),
    bookings: _maps(
      json['bookings'],
    ).map(CentreBooking.fromJson).toList(growable: false),
    riskEvidence: _maps(json['risk_evidence']),
  );
  final String id;
  final String displayName;
  final List<Map<String, dynamic>> assignments;
  final List<CentreBooking> bookings;
  final List<Map<String, dynamic>> riskEvidence;
  String get name => displayName;
  String get status => 'active';
}

class CentreRoom {
  const CentreRoom({
    required this.id,
    required this.name,
    required this.status,
  });
  factory CentreRoom.fromJson(Map<String, dynamic> json) => CentreRoom(
    id: '${json['id']}',
    name: json['name']?.toString() ?? 'Room',
    status: json['status']?.toString() ?? 'active',
  );
  final String id;
  final String name;
  final String status;
}

class CentreRoomHours {
  const CentreRoomHours({
    required this.id,
    required this.roomId,
    required this.weekday,
    required this.opensAt,
    required this.closesAt,
    required this.validFrom,
    this.validUntil,
  });
  factory CentreRoomHours.fromJson(Map<String, dynamic> json) =>
      CentreRoomHours(
        id: '${json['id']}',
        roomId: '${json['room_id']}',
        weekday: _integer(json['weekday']),
        opensAt: '${json['opens_at']}',
        closesAt: '${json['closes_at']}',
        validFrom: '${json['valid_from']}',
        validUntil: json['valid_until']?.toString(),
      );
  final String id;
  final String roomId;
  final int weekday;
  final String opensAt;
  final String closesAt;
  final String validFrom;
  final String? validUntil;
}

class CentreRooms {
  const CentreRooms({required this.items, required this.hours});
  final List<CentreRoom> items;
  final List<CentreRoomHours> hours;
}

class CentreService {
  const CentreService({
    required this.id,
    required this.name,
    this.description,
    required this.durationMinutes,
    required this.indicativePriceMinor,
    required this.currencyCode,
    required this.status,
  });
  factory CentreService.fromJson(Map<String, dynamic> json) => CentreService(
    id: '${json['id']}',
    name: json['name']?.toString() ?? 'Service',
    description: json['description']?.toString(),
    durationMinutes: _integer(json['duration_minutes']),
    indicativePriceMinor: _integer(json['indicative_price_minor']),
    currencyCode: json['currency_code']?.toString() ?? 'INR',
    status: json['status']?.toString() ?? 'active',
  );
  final String id;
  final String name;
  final String? description;
  final int durationMinutes;
  final int indicativePriceMinor;
  final String currencyCode;
  final String status;
}

class RoomServiceLink {
  const RoomServiceLink({
    required this.id,
    required this.roomId,
    required this.serviceId,
    this.unlinkedAt,
  });
  factory RoomServiceLink.fromJson(Map<String, dynamic> json) =>
      RoomServiceLink(
        id: '${json['id']}',
        roomId: '${json['room_id']}',
        serviceId: '${json['service_id']}',
        unlinkedAt: json['unlinked_at']?.toString(),
      );
  final String id;
  final String roomId;
  final String serviceId;
  final String? unlinkedAt;
}

class CentreServices {
  const CentreServices({required this.items, required this.compatibility});
  final List<CentreService> items;
  final List<RoomServiceLink> compatibility;
}

Map<String, dynamic> _map(Object? value) =>
    (value as Map?)?.cast<String, dynamic>() ?? const {};
List<Map<String, dynamic>> _maps(Object? value) => [
  for (final row in value as List? ?? const []) _map(row),
];
List<String> _strings(Object? value) => [
  for (final item in value as List? ?? const []) '$item',
];
int _integer(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;
double? _decimal(Object? value) => value == null
    ? null
    : (value is num ? value.toDouble() : double.tryParse('$value'));
