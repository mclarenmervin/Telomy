import '../../health/models/health_measurement.dart';

class DailyActivity {
  const DailyActivity({
    required this.date,
    required this.steps,
    required this.distanceKm,
    required this.activeCalories,
    required this.activeMinutes,
    required this.sedentaryMinutes,
    required this.sources,
  });
  final DateTime date;
  final double steps;
  final double distanceKm;
  final double activeCalories;
  final double activeMinutes;
  final double sedentaryMinutes;
  final Set<MeasurementSource> sources;
}

class ActivityAnalysis {
  const ActivityAnalysis();

  DailyActivity summarize(List<HealthMeasurement> all, DateTime date) {
    final start = DateTime(date.year, date.month, date.day);
    final end = start.add(const Duration(days: 1));
    final values = all
        .where(
          (item) =>
              !item.recordedAt.isBefore(start) && item.recordedAt.isBefore(end),
        )
        .toList();
    return DailyActivity(
      date: start,
      steps: _total(values, MeasurementType.steps, cumulativeWearable: true),
      distanceKm: _total(values, MeasurementType.distance),
      activeCalories: _total(values, MeasurementType.calories),
      activeMinutes: _total(values, MeasurementType.activity),
      sedentaryMinutes: _total(values, MeasurementType.sedentaryTime),
      sources: values
          .where((item) => _types.contains(item.measurementType))
          .map((item) => item.source)
          .toSet(),
    );
  }

  double _total(
    List<HealthMeasurement> values,
    MeasurementType type, {
    bool cumulativeWearable = false,
  }) {
    final matching = values
        .where((item) => item.measurementType == type)
        .toList();
    if (!cumulativeWearable) {
      return matching.fold(0.0, (sum, item) => sum + item.value);
    }
    final totals = <String, double>{};
    var intervalTotal = 0.0;
    for (final item in matching) {
      if (item.source == MeasurementSource.wearable ||
          item.source == MeasurementSource.manual) {
        final key = '${item.source.name}:${item.deviceId ?? 'manual'}';
        final previous = totals[key] ?? 0;
        if (item.value > previous) totals[key] = item.value;
      } else {
        intervalTotal += item.value;
      }
    }
    return intervalTotal + totals.values.fold(0.0, (sum, value) => sum + value);
  }

  static const _types = <MeasurementType>{
    MeasurementType.steps,
    MeasurementType.distance,
    MeasurementType.calories,
    MeasurementType.activity,
    MeasurementType.sedentaryTime,
  };
}
