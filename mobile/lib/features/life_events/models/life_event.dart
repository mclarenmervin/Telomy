import 'package:flutter/material.dart';

/// One kind of life event the user can log.
///
/// `key` is the value written to `events.event_type` and is what the backend
/// reasons about, so it must stay in the agent's taxonomy. The label and icon
/// exist only for this screen.
@immutable
class LifeEventType {
  const LifeEventType({
    required this.key,
    required this.label,
    required this.icon,
    required this.blurb,
  });

  final String key;
  final String label;
  final IconData icon;

  /// One line explaining what logging this buys the user, shown under the label.
  final String blurb;

  /// The launch set. Alcohol, sauna and cold plunge are the events the detector
  /// will eventually catch on its own; smoking never will, which is exactly why
  /// it stays a first-class manual entry rather than being left out.
  static const all = <LifeEventType>[
    LifeEventType(
      key: 'alcohol',
      label: 'Alcohol',
      icon: Icons.local_bar_outlined,
      blurb: 'See the cost to tonight’s recovery',
    ),
    LifeEventType(
      key: 'sauna',
      label: 'Sauna',
      icon: Icons.whatshot_outlined,
      blurb: 'Track heat load as it builds',
    ),
    LifeEventType(
      key: 'cold_plunge',
      label: 'Cold plunge',
      icon: Icons.ac_unit_outlined,
      blurb: 'Watch the rebound in real time',
    ),
    LifeEventType(
      key: 'eating',
      label: 'Meal',
      icon: Icons.restaurant_outlined,
      blurb: 'How your body answers a meal',
    ),
    LifeEventType(
      key: 'caffeine',
      label: 'Caffeine',
      icon: Icons.coffee_outlined,
      blurb: 'Catch a late cup before it costs you',
    ),
    LifeEventType(
      key: 'smoking',
      label: 'Smoking',
      icon: Icons.smoking_rooms_outlined,
      blurb: 'No sensor sees this — tell us and we’ll measure it',
    ),
  ];

  static LifeEventType? byKey(String? key) {
    for (final type in all) {
      if (type.key == key) return type;
    }
    return null;
  }
}

/// A row of the backend `events` table, as this screen needs it.
@immutable
class LifeEvent {
  const LifeEvent({
    required this.id,
    required this.eventType,
    required this.status,
    required this.startedAt,
    this.endedAt,
  });

  final String id;
  final String eventType;
  final String status;
  final DateTime startedAt;
  final DateTime? endedAt;

  /// Mirrors the backend's OPEN_STATUSES. An event stops being open the moment
  /// the user taps stop, which is also when the check-in timer stops.
  bool get isOpen => status == 'started' || status == 'confirmed';

  /// The app's label for this type, or the raw key when the backend knows an
  /// event type this build does not — better a plain word than a blank card.
  String get label => LifeEventType.byKey(eventType)?.label ?? eventType;

  IconData get icon =>
      LifeEventType.byKey(eventType)?.icon ?? Icons.bolt_outlined;

  Duration elapsed({DateTime? now}) =>
      (now ?? DateTime.now().toUtc()).difference(startedAt);

  static LifeEvent? fromRow(Map<String, dynamic> row) {
    final id = row['id']?.toString();
    final startedAt = DateTime.tryParse(row['started_at']?.toString() ?? '');
    if (id == null || id.isEmpty || startedAt == null) return null;
    return LifeEvent(
      id: id,
      eventType: row['event_type']?.toString() ?? '',
      status: row['status']?.toString() ?? '',
      startedAt: startedAt.toUtc(),
      endedAt: DateTime.tryParse(row['ended_at']?.toString() ?? '')?.toUtc(),
    );
  }
}
