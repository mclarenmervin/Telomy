import '../../health/models/health_measurement.dart';
import '../models/journal_entry.dart';
import '../models/wellness_data.dart';

class WellnessAnalytics {
  WellnessAnalytics(this.data, this.from, this.to);
  final WellnessData data;
  final DateTime from, to;
  bool includes(DateTime at) => !at.isBefore(from) && !at.isAfter(to);
  List<JournalEntry> get entries =>
      data.entries.where((e) => includes(e.recordedAt)).toList();
  List<HealthMeasurement> readings(MeasurementType type) =>
      data.measurements
          .where((m) => m.measurementType == type && includes(m.recordedAt))
          .toList()
        ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
  double total(EntryKind kind, String field) => entries
      .where((e) => e.kind == kind)
      .fold(0, (sum, e) => sum + e.number(field));
  double? average(MeasurementType type) {
    final list = readings(type);
    return list.isEmpty
        ? null
        : list.fold<double>(0, (sum, m) => sum + m.value) / list.length;
  }

  double get totalSteps {
    final daily = <String, HealthMeasurement>{};
    for (final m in readings(MeasurementType.steps)) {
      final day =
          '${m.recordedAt.year}-${m.recordedAt.month}-${m.recordedAt.day}';
      daily[day] = m;
    }
    return daily.values.fold(0, (sum, m) => sum + m.value);
  }

  String summary() {
    final hr = average(MeasurementType.heartRate);
    final sleep = average(MeasurementType.sleep);
    return '${entries.length} journal records and ${data.measurements.where((m) => includes(m.recordedAt)).length} measurements in this period.\n\n'
        '${hr == null ? 'No heart-rate readings.' : 'Average recorded heart rate: ${hr.toStringAsFixed(0)} BPM.'}\n'
        '${sleep == null ? 'No sleep readings.' : 'Average logged sleep: ${sleep.toStringAsFixed(1)} hours.'}\n'
        'Steps: ${totalSteps.toStringAsFixed(0)} (latest daily totals).\n'
        'Workouts: ${total(EntryKind.workout, 'duration').toStringAsFixed(0)} minutes.\n'
        'Logged food: ${total(EntryKind.meal, 'calories').toStringAsFixed(0)} kcal; protein ${total(EntryKind.meal, 'protein').toStringAsFixed(0)} g.\n'
        'Water: ${total(EntryKind.water, 'amount').toStringAsFixed(0)} ml.\n\n'
        'Missing records are not zero activity. These summaries describe your entries and do not diagnose a condition.';
  }
}
