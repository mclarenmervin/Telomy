import '../../journal/models/journal_entry.dart';
import '../../journal/models/wellness_data.dart';

class MedicationSummary {
  const MedicationSummary({
    required this.medication,
    required this.active,
    required this.takenToday,
    required this.takenLastSevenDays,
    required this.expectedLastSevenDays,
  });
  final JournalEntry medication;
  final bool active, takenToday;
  final int takenLastSevenDays, expectedLastSevenDays;
  double get adherence => expectedLastSevenDays == 0
      ? 0
      : (takenLastSevenDays / expectedLastSevenDays).clamp(0, 1);
}

class MedicationService {
  const MedicationService();

  List<MedicationSummary> summaries(WellnessData data, DateTime now) {
    final medications =
        data.entries
            .where((entry) => entry.kind == EntryKind.medication)
            .toList()
          ..sort((a, b) => a.title.compareTo(b.title));
    return [
      for (final medication in medications) _summary(data, medication, now),
    ];
  }

  MedicationSummary _summary(
    WellnessData data,
    JournalEntry medication,
    DateTime now,
  ) {
    final today = DateTime(now.year, now.month, now.day);
    final start =
        DateTime.tryParse(medication.fields['startDate'] ?? '') ??
        DateTime(
          medication.recordedAt.year,
          medication.recordedAt.month,
          medication.recordedAt.day,
        );
    final end = DateTime.tryParse(medication.fields['endDate'] ?? '');
    final active =
        !start.isAfter(today) && (end == null || !end.isBefore(today));
    final doses = data.entries.where(
      (entry) =>
          entry.kind == EntryKind.medicationDose &&
          (entry.parentId == medication.id ||
              entry.fields['medicationId'] == medication.id),
    );
    final weekStart = today.subtract(const Duration(days: 6));
    final recent = doses.where(
      (dose) =>
          !dose.recordedAt.isBefore(weekStart) &&
          dose.recordedAt.isBefore(today.add(const Duration(days: 1))),
    );
    final takenDays = <String>{
      for (final dose in recent) _key(dose.recordedAt),
    };
    return MedicationSummary(
      medication: medication,
      active: active,
      takenToday: doses.any((dose) => _key(dose.recordedAt) == _key(today)),
      takenLastSevenDays: takenDays.length,
      expectedLastSevenDays: _expectedDays(start, end, today),
    );
  }

  JournalEntry planDose(JournalEntry medication) => JournalEntry.create(
    kind: EntryKind.medicationDose,
    title: medication.title,
    recordedAt: DateTime.now(),
    fields: {
      'dose': medication.fields['dose'] ?? '',
      'medicationId': medication.id,
    },
    parentId: medication.id,
  );

  int _expectedDays(DateTime start, DateTime? end, DateTime today) {
    final weekStart = today.subtract(const Duration(days: 6));
    var count = 0;
    for (
      var day = weekStart;
      !day.isAfter(today);
      day = day.add(const Duration(days: 1))
    ) {
      if (!day.isBefore(start) && (end == null || !day.isAfter(end))) count++;
    }
    return count;
  }

  String _key(DateTime value) => '${value.year}-${value.month}-${value.day}';
}
