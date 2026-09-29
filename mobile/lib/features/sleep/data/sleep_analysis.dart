import '../../health/models/health_measurement.dart';

class SleepSummary {
  const SleepSummary({
    required this.date,
    required this.totalHours,
    required this.timeInBedHours,
    required this.bedtime,
    required this.wakeTime,
    required this.efficiency,
    required this.stageHours,
    required this.score,
    required this.scoreDrivers,
    required this.sources,
  });

  final DateTime date;
  final double totalHours;
  final double timeInBedHours;
  final DateTime? bedtime;
  final DateTime? wakeTime;
  final double? efficiency;
  final Map<MeasurementType, double> stageHours;
  final int? score;
  final Map<String, int> scoreDrivers;
  final Set<MeasurementSource> sources;
}

class SleepAnalysis {
  const SleepAnalysis();

  SleepSummary summarize(
    List<HealthMeasurement> all,
    DateTime date, {
    double targetHours = 8,
  }) {
    final effectiveTarget = targetHours > 0 ? targetHours : 8.0;
    final day = DateTime(date.year, date.month, date.day);
    final next = day.add(const Duration(days: 1));
    final records = all.where((measurement) {
      if (!_sleepTypes.contains(measurement.measurementType)) return false;
      final end = _end(measurement);
      return !end.isBefore(day) && end.isBefore(next);
    }).toList();
    if (records.isEmpty) {
      return SleepSummary(
        date: day,
        totalHours: 0,
        timeInBedHours: 0,
        bedtime: null,
        wakeTime: null,
        efficiency: null,
        stageHours: const {},
        score: null,
        scoreDrivers: const {},
        sources: const {},
      );
    }

    final asleep = records
        .where(
          (measurement) => _asleepTypes.contains(measurement.measurementType),
        )
        .toList();
    final inBed = records
        .where(
          (measurement) =>
              measurement.measurementType == MeasurementType.sleepInBed,
        )
        .toList();
    final total = _unionHours(asleep);
    final bedtime = records
        .map((measurement) => measurement.recordedAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final wake = records.map(_end).reduce((a, b) => a.isAfter(b) ? a : b);
    final timeInBed = inBed.isNotEmpty
        ? _unionHours(inBed)
        : wake.difference(bedtime).inMinutes / 60;
    final efficiency = timeInBed > 0
        ? (total / timeInBed * 100).clamp(0, 100).toDouble()
        : null;
    final durationPoints =
        ((1 - (total - effectiveTarget).abs() / effectiveTarget).clamp(0, 1) *
                70)
            .round();
    final efficiencyPoints = efficiency == null
        ? 0
        : ((efficiency / 100).clamp(0, 1) * 30).round();
    final stages = <MeasurementType, double>{
      for (final type in _stageTypes)
        type: records
            .where((measurement) => measurement.measurementType == type)
            .fold(0.0, (sum, measurement) => sum + _durationHours(measurement)),
    }..removeWhere((_, value) => value <= 0);
    return SleepSummary(
      date: day,
      totalHours: total,
      timeInBedHours: timeInBed,
      bedtime: bedtime,
      wakeTime: wake,
      efficiency: efficiency,
      stageHours: stages,
      score: durationPoints + efficiencyPoints,
      scoreDrivers: {
        'Duration': durationPoints,
        'Efficiency': efficiencyPoints,
      },
      sources: records.map((measurement) => measurement.source).toSet(),
    );
  }

  static const _sleepTypes = <MeasurementType>{
    MeasurementType.sleep,
    MeasurementType.sleepInBed,
    MeasurementType.sleepLight,
    MeasurementType.sleepDeep,
    MeasurementType.sleepRem,
    MeasurementType.sleepAwake,
  };
  static const _stageTypes = <MeasurementType>{
    MeasurementType.sleepLight,
    MeasurementType.sleepDeep,
    MeasurementType.sleepRem,
    MeasurementType.sleepAwake,
  };
  static const _asleepTypes = <MeasurementType>{
    MeasurementType.sleep,
    MeasurementType.sleepLight,
    MeasurementType.sleepDeep,
    MeasurementType.sleepRem,
  };

  DateTime _end(HealthMeasurement value) =>
      value.endedAt ??
      value.recordedAt.add(Duration(minutes: (value.value * 60).round()));

  double _durationHours(HealthMeasurement value) =>
      _end(value).difference(value.recordedAt).inMinutes / 60;

  double _unionHours(List<HealthMeasurement> records) {
    if (records.isEmpty) return 0;
    final spans =
        records
            .map((measurement) => (measurement.recordedAt, _end(measurement)))
            .where((span) => span.$2.isAfter(span.$1))
            .toList()
          ..sort((a, b) => a.$1.compareTo(b.$1));
    if (spans.isEmpty) {
      return records.fold(0.0, (sum, measurement) => sum + measurement.value);
    }
    var start = spans.first.$1;
    var end = spans.first.$2;
    var minutes = 0;
    for (final span in spans.skip(1)) {
      if (!span.$1.isAfter(end)) {
        if (span.$2.isAfter(end)) end = span.$2;
      } else {
        minutes += end.difference(start).inMinutes;
        start = span.$1;
        end = span.$2;
      }
    }
    minutes += end.difference(start).inMinutes;
    return minutes / 60;
  }
}
