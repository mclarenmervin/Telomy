import 'package:flutter/foundation.dart';

/// The queue's numbers. Any of them may be null, and null is not zero.
///
/// `stranded_total` reading 0 because the read failed, on a screen whose
/// entire job is to show that people are not being told things, is the exact
/// failure the server guards against by returning null. The screen has to
/// carry that distinction through rather than defaulting it away.
@immutable
class QueueHealth {
  const QueueHealth({
    this.depth,
    this.strandedTotal,
    this.claimed,
    this.oldestWaitingHours,
  });

  final int? depth;
  final int? strandedTotal;
  final int? claimed;
  final double? oldestWaitingHours;

  bool get unreadable => depth == null && strandedTotal == null;

  static QueueHealth fromJson(Map<String, dynamic> json) => QueueHealth(
        depth: (json['depth'] as num?)?.toInt(),
        strandedTotal: (json['stranded_total'] as num?)?.toInt(),
        claimed: (json['claimed'] as num?)?.toInt(),
        oldestWaitingHours: (json['oldest_waiting_hours'] as num?)?.toDouble(),
      );
}

@immutable
class CatalogueCount {
  const CatalogueCount({
    required this.name,
    required this.path,
    required this.version,
    required this.total,
    required this.signed,
    required this.unsigned,
  });

  final String name;
  final String path;
  final String version;
  final int total;
  final int signed;
  final int unsigned;

  static CatalogueCount fromJson(String name, Map<String, dynamic> json) =>
      CatalogueCount(
        name: name,
        path: json['path']?.toString() ?? '',
        version: json['version']?.toString() ?? '',
        total: (json['total'] as num?)?.toInt() ?? 0,
        signed: (json['signed'] as num?)?.toInt() ?? 0,
        unsigned: (json['unsigned'] as num?)?.toInt() ?? 0,
      );
}

@immutable
class LapsingLicence {
  const LapsingLicence({
    required this.fullName,
    required this.registrationNumber,
    required this.daysLeft,
    required this.expired,
  });

  final String fullName;
  final String registrationNumber;
  final int daysLeft;
  final bool expired;

  static LapsingLicence fromJson(Map<String, dynamic> json) => LapsingLicence(
        fullName: json['full_name']?.toString() ?? '',
        registrationNumber: json['registration_number']?.toString() ?? '',
        daysLeft: (json['days_left'] as num?)?.toInt() ?? 0,
        expired: json['expired'] == true,
      );
}

@immutable
class PlatformHealth {
  const PlatformHealth({
    required this.queue,
    required this.catalogues,
    required this.roles,
    required this.cataloguesUnsigned,
    required this.activeClinicians,
    required this.lapsing,
  });

  final QueueHealth queue;
  final List<CatalogueCount> catalogues;
  final Map<String, int> roles;
  final int cataloguesUnsigned;

  /// Null means the registrations could not be read. Zero means there are
  /// none, which is a different and much more significant fact.
  final int? activeClinicians;

  final List<LapsingLicence> lapsing;

  static PlatformHealth fromJson(Map<String, dynamic> json) {
    final catalogue = (json['catalogue'] as Map?)?.cast<String, dynamic>() ?? {};
    final perFile =
        (catalogue['catalogues'] as Map?)?.cast<String, dynamic>() ?? {};
    final clinicians =
        (json['clinicians'] as Map?)?.cast<String, dynamic>() ?? {};

    return PlatformHealth(
      queue: QueueHealth.fromJson(
          (json['queue'] as Map?)?.cast<String, dynamic>() ?? {}),
      catalogues: [
        for (final entry in perFile.entries)
          CatalogueCount.fromJson(
              entry.key, (entry.value as Map).cast<String, dynamic>()),
      ],
      cataloguesUnsigned: (catalogue['unsigned'] as num?)?.toInt() ?? 0,
      roles: {
        for (final entry
            in ((json['roles'] as Map?)?.cast<String, dynamic>() ?? {}).entries)
          entry.key: (entry.value as num?)?.toInt() ?? 0,
      },
      activeClinicians: (clinicians['active'] as num?)?.toInt(),
      lapsing: [
        for (final row in (clinicians['expiring_soon'] as List?) ?? const [])
          LapsingLicence.fromJson((row as Map).cast<String, dynamic>()),
      ],
    );
  }
}
