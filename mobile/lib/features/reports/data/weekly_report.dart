import '../../health/models/health_measurement.dart';
import '../../health/services/longi_score_service.dart';
import '../../journal/models/journal_entry.dart';
import '../../journal/models/wellness_data.dart';

class WeeklyMetric {
  const WeeklyMetric(this.label, this.value, this.unit, this.change);
  final String label, unit;
  final double? value, change;
}

class WeeklyReport {
  const WeeklyReport({
    required this.from,
    required this.to,
    required this.metrics,
    required this.score,
    required this.scoreChange,
    required this.activeDays,
    required this.loggedDays,
    required this.highlights,
  });
  final DateTime from, to;
  final List<WeeklyMetric> metrics;
  final double? score, scoreChange;
  final int activeDays, loggedDays;
  final List<String> highlights;
}

class WeeklyReportService {
  const WeeklyReportService();

  WeeklyReport build(WellnessData data, DateTime endDate) {
    final to = DateTime(endDate.year, endDate.month, endDate.day, 23, 59, 59);
    final from = DateTime(
      endDate.year,
      endDate.month,
      endDate.day,
    ).subtract(const Duration(days: 6));
    final previousTo = from.subtract(const Duration(seconds: 1));
    final previousFrom = from.subtract(const Duration(days: 7));
    final current = _summary(data, from, to);
    final previous = _summary(data, previousFrom, previousTo);
    final metrics = <WeeklyMetric>[
      _metric('Daily steps', current.steps, previous.steps, 'steps'),
      _metric('Sleep', current.sleep, previous.sleep, 'h/night'),
      _metric(
        'Resting heart rate',
        current.restingHeartRate,
        previous.restingHeartRate,
        'bpm',
      ),
      _metric('HRV', current.hrv, previous.hrv, 'ms'),
      _metric('Food energy', current.calories, previous.calories, 'kcal/day'),
      _metric('Protein', current.protein, previous.protein, 'g/day'),
      _metric(
        'Training',
        current.workoutMinutes,
        previous.workoutMinutes,
        'min',
      ),
    ];
    final score = _averageOrNull(_scores(data, from, to));
    final previousScore = _averageOrNull(
      _scores(data, previousFrom, previousTo),
    );
    final highlights = <String>[];
    final comparable = metrics.where((metric) => metric.change != null).toList()
      ..sort((a, b) => b.change!.abs().compareTo(a.change!.abs()));
    for (final metric in comparable.take(2)) {
      highlights.add(
        '${metric.label} ${metric.change! >= 0 ? 'increased' : 'decreased'} '
        '${metric.change!.abs().toStringAsFixed(0)}% from the previous week.',
      );
    }
    if (highlights.isEmpty) {
      highlights.add(
        'Add records across two weeks to see week-over-week changes.',
      );
    }
    return WeeklyReport(
      from: from,
      to: to,
      metrics: metrics,
      score: score,
      scoreChange: _change(score, previousScore),
      activeDays: current.activeDays,
      loggedDays: current.loggedDays,
      highlights: highlights,
    );
  }

  WeeklyMetric _metric(
    String label,
    double? current,
    double? previous,
    String unit,
  ) => WeeklyMetric(label, current, unit, _change(current, previous));

  double? _change(double? current, double? previous) =>
      current == null || previous == null || previous == 0
      ? null
      : (current - previous) / previous * 100;

  List<int> _scores(WellnessData data, DateTime from, DateTime to) {
    final scores = <int>[];
    for (
      var day = from;
      !day.isAfter(to);
      day = day.add(const Duration(days: 1))
    ) {
      final result = const LongiScoreService().calculate(
        data: data,
        measurements: data.measurements,
        date: day,
      );
      if (result.value != null) scores.add(result.value!);
    }
    return scores;
  }

  _WeekSummary _summary(WellnessData data, DateTime from, DateTime to) {
    final measurements = data.measurements
        .where(
          (item) =>
              !item.recordedAt.isBefore(from) && !item.recordedAt.isAfter(to),
        )
        .toList();
    final entries = data.entries
        .where(
          (item) =>
              !item.recordedAt.isBefore(from) && !item.recordedAt.isAfter(to),
        )
        .toList();
    final days = <String>{};
    final activeDays = <String>{};
    for (final item in measurements) {
      days.add(_dayKey(item.recordedAt));
      if (item.measurementType == MeasurementType.steps ||
          item.measurementType == MeasurementType.activity) {
        activeDays.add(_dayKey(item.recordedAt));
      }
    }
    for (final entry in entries) {
      days.add(_dayKey(entry.recordedAt));
      if (entry.kind == EntryKind.workout) {
        activeDays.add(_dayKey(entry.recordedAt));
      }
    }
    double? averageType(MeasurementType type, {bool dailyTotal = false}) {
      final values = measurements.where((m) => m.measurementType == type);
      if (values.isEmpty) return null;
      if (!dailyTotal) return _averageOrNull(values.map((m) => m.value));
      final totals = <String, double>{};
      for (final item in values) {
        totals.update(
          _dayKey(item.recordedAt),
          (value) => value + item.value,
          ifAbsent: () => item.value,
        );
      }
      return _averageOrNull(totals.values);
    }

    double? entryDailyAverage(EntryKind kind, String key) {
      final totals = <String, double>{};
      for (final entry in entries.where((e) => e.kind == kind)) {
        totals.update(
          _dayKey(entry.recordedAt),
          (value) => value + entry.number(key),
          ifAbsent: () => entry.number(key),
        );
      }
      return _averageOrNull(totals.values);
    }

    return _WeekSummary(
      steps: averageType(MeasurementType.steps, dailyTotal: true),
      sleep: averageType(MeasurementType.sleep, dailyTotal: true),
      restingHeartRate: averageType(MeasurementType.restingHeartRate),
      hrv: averageType(MeasurementType.hrv),
      calories: entryDailyAverage(EntryKind.meal, 'calories'),
      protein: entryDailyAverage(EntryKind.meal, 'protein'),
      workoutMinutes: entries
          .where((e) => e.kind == EntryKind.workout)
          .fold(0, (sum, e) => sum + e.number('duration')),
      activeDays: activeDays.length,
      loggedDays: days.length,
    );
  }

  double? _averageOrNull(Iterable<num> values) {
    final list = values.toList();
    return list.isEmpty
        ? null
        : list.fold<double>(0, (sum, value) => sum + value) / list.length;
  }

  String _dayKey(DateTime value) => '${value.year}-${value.month}-${value.day}';
}

class _WeekSummary {
  const _WeekSummary({
    required this.steps,
    required this.sleep,
    required this.restingHeartRate,
    required this.hrv,
    required this.calories,
    required this.protein,
    required this.workoutMinutes,
    required this.activeDays,
    required this.loggedDays,
  });
  final double? steps, sleep, restingHeartRate, hrv, calories, protein;
  final double workoutMinutes;
  final int activeDays, loggedDays;
}
