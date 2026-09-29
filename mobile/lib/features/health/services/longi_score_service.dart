import '../../journal/models/journal_entry.dart';
import '../../journal/models/wellness_data.dart';
import '../models/health_measurement.dart';

class LongiScoreComponent {
  const LongiScoreComponent({
    required this.name,
    required this.score,
    required this.weight,
    required this.detail,
  });
  final String name, detail;
  final double score, weight;
}

class LongiScoreResult {
  const LongiScoreResult({
    required this.value,
    required this.coverage,
    required this.confidence,
    required this.components,
    required this.missingInputs,
    required this.version,
  });
  final int? value;
  final double coverage, confidence;
  final List<LongiScoreComponent> components;
  final List<String> missingInputs;
  final String version;
}

class LongiScoreService {
  const LongiScoreService();
  static const version = 'longiscore-v1.0.0';
  static const _weights = <String, double>{
    'Sleep': .25,
    'Activity': .20,
    'HRV': .15,
    'Resting heart rate': .15,
    'Stress': .15,
    'Daily habits': .10,
  };

  LongiScoreResult calculate({
    required WellnessData data,
    required List<HealthMeasurement> measurements,
    required DateTime date,
  }) {
    final day = DateTime(date.year, date.month, date.day);
    final end = day.add(const Duration(days: 1));
    final components = <LongiScoreComponent>[];
    final missing = <String>[];

    final sleep = _dayTotal(measurements, MeasurementType.sleep, day, end);
    final sleepGoal = data.goal('sleepGoal', 8);
    if (sleep > 0) {
      _add(
        components,
        'Sleep',
        _goalScore(sleep, sleepGoal),
        '${sleep.toStringAsFixed(1)} of ${sleepGoal.toStringAsFixed(1)} hours',
      );
    } else {
      missing.add('Sleep');
    }

    final steps = _dayTotal(measurements, MeasurementType.steps, day, end);
    final activity = _dayTotal(
      measurements,
      MeasurementType.activity,
      day,
      end,
    );
    if (steps > 0 || activity > 0) {
      final stepScore = _goalScore(steps, data.goal('stepsGoal', 8000));
      final activityScore = _goalScore(activity, data.goal('activityGoal', 30));
      _add(
        components,
        'Activity',
        steps > 0 && activity > 0
            ? (stepScore + activityScore) / 2
            : steps > 0
            ? stepScore
            : activityScore,
        '${steps.round()} steps · ${activity.round()} active min',
      );
    } else {
      missing.add('Activity');
    }

    _baselineComponent(
      measurements,
      MeasurementType.hrv,
      'HRV',
      day,
      end,
      true,
      components,
      missing,
    );
    _baselineComponent(
      measurements,
      MeasurementType.restingHeartRate,
      'Resting heart rate',
      day,
      end,
      false,
      components,
      missing,
    );

    final stressValues = _dayValues(
      measurements,
      MeasurementType.stress,
      day,
      end,
    );
    if (stressValues.isNotEmpty) {
      final stress = _average(stressValues).clamp(0, 100).toDouble();
      _add(
        components,
        'Stress',
        100 - stress,
        '${stress.round()} / 100 recorded stress proxy',
      );
    } else {
      missing.add('Stress');
    }

    final entries = data.entries.where(
      (entry) =>
          !entry.recordedAt.isBefore(day) && entry.recordedAt.isBefore(end),
    );
    final habits = <String>{
      for (final entry in entries)
        if ({
          EntryKind.meal,
          EntryKind.water,
          EntryKind.checkIn,
        }.contains(entry.kind))
          entry.kind.name,
    };
    if (habits.isNotEmpty) {
      _add(
        components,
        'Daily habits',
        habits.length / 3 * 100,
        '${habits.length} of 3 daily check-in categories recorded',
      );
    } else {
      missing.add('Daily habits');
    }

    final coverage = components.fold(0.0, (sum, item) => sum + item.weight);
    final weighted = components.fold(
      0.0,
      (sum, item) => sum + item.score * item.weight,
    );
    final value = components.length < 3 || coverage == 0
        ? null
        : (weighted / coverage).round().clamp(0, 100);
    final sampleDays = _daysWithData(measurements, day);
    final confidence = (coverage * (sampleDays / 7).clamp(.35, 1))
        .clamp(0, 1)
        .toDouble();
    return LongiScoreResult(
      value: value,
      coverage: coverage,
      confidence: confidence,
      components: components,
      missingInputs: missing,
      version: version,
    );
  }

  void _add(
    List<LongiScoreComponent> into,
    String name,
    double score,
    String detail,
  ) {
    into.add(
      LongiScoreComponent(
        name: name,
        score: score.clamp(0, 100).toDouble(),
        weight: _weights[name]!,
        detail: detail,
      ),
    );
  }

  void _baselineComponent(
    List<HealthMeasurement> all,
    MeasurementType type,
    String name,
    DateTime day,
    DateTime end,
    bool higherIsBetter,
    List<LongiScoreComponent> into,
    List<String> missing,
  ) {
    final current = _dayValues(all, type, day, end);
    final baseline = all
        .where(
          (item) =>
              item.measurementType == type &&
              item.recordedAt.isBefore(day) &&
              !item.recordedAt.isBefore(day.subtract(const Duration(days: 30))),
        )
        .map((item) => item.value)
        .toList();
    if (current.isEmpty || baseline.length < 3) {
      missing.add(name);
      return;
    }
    final currentAverage = _average(current);
    final baselineAverage = _average(baseline);
    final change = baselineAverage == 0
        ? 0
        : (currentAverage - baselineAverage) / baselineAverage;
    _add(
      into,
      name,
      70 + (higherIsBetter ? change : -change) * 100,
      '${currentAverage.toStringAsFixed(1)} vs ${baselineAverage.toStringAsFixed(1)} 30-day baseline',
    );
  }

  List<double> _dayValues(
    List<HealthMeasurement> all,
    MeasurementType type,
    DateTime start,
    DateTime end,
  ) => all
      .where(
        (item) =>
            item.measurementType == type &&
            !item.recordedAt.isBefore(start) &&
            item.recordedAt.isBefore(end),
      )
      .map((item) => item.value)
      .toList();

  double _dayTotal(
    List<HealthMeasurement> all,
    MeasurementType type,
    DateTime start,
    DateTime end,
  ) => _dayValues(all, type, start, end).fold(0, (sum, value) => sum + value);
  double _average(List<double> values) =>
      values.fold(0.0, (sum, value) => sum + value) / values.length;
  double _goalScore(double value, double goal) =>
      goal <= 0 ? 0 : (value / goal * 100).clamp(0, 100).toDouble();
  int _daysWithData(List<HealthMeasurement> all, DateTime day) => {
    for (final item in all)
      if (!item.recordedAt.isBefore(day.subtract(const Duration(days: 6))) &&
          item.recordedAt.isBefore(day.add(const Duration(days: 1))))
        '${item.recordedAt.year}-${item.recordedAt.month}-${item.recordedAt.day}',
  }.length;
}
