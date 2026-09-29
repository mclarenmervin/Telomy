import '../../health/models/health_measurement.dart';
import '../../sleep/data/sleep_analysis.dart';

class ReadinessConfig {
  const ReadinessConfig({
    this.hrvWeight = 0.22,
    this.restingHeartRateWeight = 0.18,
    this.sleepDurationWeight = 0.22,
    this.sleepConsistencyWeight = 0.12,
    this.temperatureWeight = 0.10,
    this.previousActivityWeight = 0.08,
    this.stressWeight = 0.08,
    this.modelVersion = 'readiness-v1',
  });
  final double hrvWeight;
  final double restingHeartRateWeight;
  final double sleepDurationWeight;
  final double sleepConsistencyWeight;
  final double temperatureWeight;
  final double previousActivityWeight;
  final double stressWeight;
  final String modelVersion;
}

class ReadinessDriver {
  const ReadinessDriver({
    required this.name,
    required this.score,
    required this.weight,
    required this.detail,
  });
  final String name;
  final double score;
  final double weight;
  final String detail;
}

class ReadinessResult {
  const ReadinessResult({
    required this.score,
    required this.drivers,
    required this.missingInputs,
    required this.recommendation,
    required this.modelVersion,
  });
  final int? score;
  final List<ReadinessDriver> drivers;
  final List<String> missingInputs;
  final String recommendation;
  final String modelVersion;
}

class ReadinessService {
  const ReadinessService({this.config = const ReadinessConfig()});
  final ReadinessConfig config;

  ReadinessResult calculate({
    required List<HealthMeasurement> measurements,
    required DateTime date,
    double sleepGoal = 8,
    double activityGoal = 30,
  }) {
    final day = DateTime(date.year, date.month, date.day);
    final baselineStart = day.subtract(const Duration(days: 30));
    final drivers = <ReadinessDriver>[];
    final missing = <String>[];

    _baselineDriver(
      measurements,
      MeasurementType.hrv,
      day,
      baselineStart,
      config.hrvWeight,
      'HRV',
      higherIsBetter: true,
      into: drivers,
      missing: missing,
    );
    _baselineDriver(
      measurements,
      MeasurementType.restingHeartRate,
      day,
      baselineStart,
      config.restingHeartRateWeight,
      'Resting heart rate',
      higherIsBetter: false,
      into: drivers,
      missing: missing,
    );

    final sleep = const SleepAnalysis().summarize(
      measurements,
      day,
      targetHours: sleepGoal,
    );
    if (sleep.totalHours > 0) {
      final durationScore =
          (100 - (sleep.totalHours - sleepGoal).abs() / sleepGoal * 100)
              .clamp(0, 100)
              .toDouble();
      drivers.add(
        ReadinessDriver(
          name: 'Sleep duration',
          score: durationScore,
          weight: config.sleepDurationWeight,
          detail:
              '${sleep.totalHours.toStringAsFixed(1)} h of ${sleepGoal.toStringAsFixed(1)} h goal',
        ),
      );
      final bedtimes = <DateTime>[];
      for (var offset = 1; offset <= 29; offset++) {
        final night = const SleepAnalysis().summarize(
          measurements,
          day.subtract(Duration(days: offset)),
          targetHours: sleepGoal,
        );
        if (night.bedtime != null) bedtimes.add(night.bedtime!);
      }
      if (bedtimes.length >= 3 && sleep.bedtime != null) {
        final minuteValues = bedtimes.map(_nightMinute).toList();
        final baseline = _average(minuteValues);
        final difference = (_nightMinute(sleep.bedtime!) - baseline).abs();
        final wrapped = difference > 720 ? 1440 - difference : difference;
        drivers.add(
          ReadinessDriver(
            name: 'Sleep consistency',
            score: (100 - wrapped / 1.8).clamp(0, 100).toDouble(),
            weight: config.sleepConsistencyWeight,
            detail: '${wrapped.round()} min from your usual bedtime',
          ),
        );
      } else {
        missing.add('Sleep consistency');
      }
    } else {
      missing.addAll(['Sleep duration', 'Sleep consistency']);
    }

    _temperatureDriver(measurements, day, baselineStart, drivers, missing);
    _activityDriver(measurements, day, activityGoal, drivers, missing);
    _stressDriver(measurements, day, drivers, missing);

    if (drivers.length < 2) {
      return ReadinessResult(
        score: null,
        drivers: drivers,
        missingInputs: missing,
        recommendation: 'More data is needed before estimating readiness.',
        modelVersion: config.modelVersion,
      );
    }
    final totalWeight = drivers.fold(0.0, (sum, driver) => sum + driver.weight);
    final score =
        (drivers.fold(
                  0.0,
                  (sum, driver) => sum + driver.score * driver.weight,
                ) /
                totalWeight)
            .round()
            .clamp(0, 100)
            .toInt();
    final recommendation = score < 40
        ? 'Low readiness estimate · consider recovery-focused movement and reduce training intensity.'
        : score < 70
        ? 'Moderate readiness estimate · keep training controlled and respond to how you feel.'
        : 'High readiness estimate · normal planned training may be appropriate if you feel well.';
    return ReadinessResult(
      score: score,
      drivers: drivers,
      missingInputs: missing,
      recommendation: recommendation,
      modelVersion: config.modelVersion,
    );
  }

  void _baselineDriver(
    List<HealthMeasurement> all,
    MeasurementType type,
    DateTime day,
    DateTime baselineStart,
    double weight,
    String name, {
    required bool higherIsBetter,
    required List<ReadinessDriver> into,
    required List<String> missing,
  }) {
    final current = _valuesForDay(all, type, day);
    final baseline = all
        .where(
          (m) =>
              m.measurementType == type &&
              !m.recordedAt.isBefore(baselineStart) &&
              m.recordedAt.isBefore(day),
        )
        .map((m) => m.value)
        .toList();
    if (current.isEmpty || baseline.length < 3) {
      missing.add(name);
      return;
    }
    final now = _average(current);
    final normal = _average(baseline);
    final change = normal == 0 ? 0 : (now - normal) / normal;
    final score = (70 + (higherIsBetter ? change : -change) * 100)
        .clamp(0, 100)
        .toDouble();
    into.add(
      ReadinessDriver(
        name: name,
        score: score,
        weight: weight,
        detail:
            '${now.toStringAsFixed(1)} vs ${normal.toStringAsFixed(1)} 30-day baseline',
      ),
    );
  }

  void _temperatureDriver(
    List<HealthMeasurement> all,
    DateTime day,
    DateTime start,
    List<ReadinessDriver> into,
    List<String> missing,
  ) {
    final current = _valuesForDay(all, MeasurementType.temperature, day);
    final baseline = all
        .where(
          (m) =>
              m.measurementType == MeasurementType.temperature &&
              !m.recordedAt.isBefore(start) &&
              m.recordedAt.isBefore(day),
        )
        .map((m) => m.value)
        .toList();
    if (current.isEmpty || baseline.length < 3) {
      missing.add('Temperature deviation');
      return;
    }
    final deviation = (_average(current) - _average(baseline)).abs();
    into.add(
      ReadinessDriver(
        name: 'Temperature deviation',
        score: (100 - deviation * 25).clamp(0, 100).toDouble(),
        weight: config.temperatureWeight,
        detail: '${deviation.toStringAsFixed(1)} °C from baseline',
      ),
    );
  }

  void _activityDriver(
    List<HealthMeasurement> all,
    DateTime day,
    double goal,
    List<ReadinessDriver> into,
    List<String> missing,
  ) {
    final previous = _valuesForDay(
      all,
      MeasurementType.activity,
      day.subtract(const Duration(days: 1)),
    );
    if (previous.isEmpty) {
      missing.add('Previous activity');
      return;
    }
    final minutes = previous.fold(0.0, (sum, value) => sum + value);
    final load = goal <= 0 ? 0 : minutes / goal;
    final score = load <= 1
        ? 80.0
        : (80 - (load - 1) * 40).clamp(0, 80).toDouble();
    into.add(
      ReadinessDriver(
        name: 'Previous activity',
        score: score,
        weight: config.previousActivityWeight,
        detail: '${minutes.round()} active min yesterday',
      ),
    );
  }

  void _stressDriver(
    List<HealthMeasurement> all,
    DateTime day,
    List<ReadinessDriver> into,
    List<String> missing,
  ) {
    final values = _valuesForDay(all, MeasurementType.stress, day);
    if (values.isEmpty) {
      missing.add('Stress');
      return;
    }
    final stress = _average(values).clamp(0, 100).toDouble();
    into.add(
      ReadinessDriver(
        name: 'Stress',
        score: 100 - stress,
        weight: config.stressWeight,
        detail: '${stress.round()} / 100 recorded stress proxy',
      ),
    );
  }

  List<double> _valuesForDay(
    List<HealthMeasurement> all,
    MeasurementType type,
    DateTime day,
  ) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return all
        .where(
          (m) =>
              m.measurementType == type &&
              !m.recordedAt.isBefore(start) &&
              m.recordedAt.isBefore(end),
        )
        .map((m) => m.value)
        .toList();
  }

  double _average(List<num> values) =>
      values.fold(0.0, (sum, value) => sum + value) / values.length;
  double _nightMinute(DateTime value) =>
      ((value.hour < 12 ? value.hour + 24 : value.hour) * 60 + value.minute)
          .toDouble();
}
