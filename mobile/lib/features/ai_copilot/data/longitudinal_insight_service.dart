import '../../health/models/health_measurement.dart';
import '../../journal/models/journal_entry.dart';
import '../../journal/models/wellness_data.dart';

enum InsightDirection { improving, declining, stable, neutral }

class LongitudinalInsight {
  const LongitudinalInsight({
    required this.title,
    required this.summary,
    required this.evidence,
    required this.direction,
    required this.confidence,
    required this.sampleDays,
  });
  final String title, summary, evidence;
  final InsightDirection direction;
  final double confidence;
  final int sampleDays;
}

class LongitudinalInsightService {
  const LongitudinalInsightService();

  List<LongitudinalInsight> build(WellnessData data, {int windowDays = 14}) {
    final today = DateTime.now();
    final currentEnd = DateTime(today.year, today.month, today.day, 23, 59, 59);
    final currentStart = DateTime(
      today.year,
      today.month,
      today.day,
    ).subtract(Duration(days: windowDays - 1));
    final previousEnd = currentStart.subtract(const Duration(seconds: 1));
    final previousStart = currentStart.subtract(Duration(days: windowDays));
    final insights = <LongitudinalInsight>[];
    _measurementInsight(
      data,
      MeasurementType.sleep,
      'Sleep duration',
      'hours',
      currentStart,
      currentEnd,
      previousStart,
      previousEnd,
      true,
      insights,
    );
    _measurementInsight(
      data,
      MeasurementType.steps,
      'Daily steps',
      'steps',
      currentStart,
      currentEnd,
      previousStart,
      previousEnd,
      true,
      insights,
      totalsByDay: true,
    );
    _measurementInsight(
      data,
      MeasurementType.restingHeartRate,
      'Resting heart rate',
      'bpm',
      currentStart,
      currentEnd,
      previousStart,
      previousEnd,
      false,
      insights,
    );
    _measurementInsight(
      data,
      MeasurementType.hrv,
      'HRV',
      'ms',
      currentStart,
      currentEnd,
      previousStart,
      previousEnd,
      true,
      insights,
    );
    _measurementInsight(
      data,
      MeasurementType.stress,
      'Stress proxy',
      '/ 100',
      currentStart,
      currentEnd,
      previousStart,
      previousEnd,
      false,
      insights,
    );
    _entryInsight(
      data,
      EntryKind.workout,
      'duration',
      'Training time',
      'minutes',
      currentStart,
      currentEnd,
      previousStart,
      previousEnd,
      true,
      insights,
    );
    _entryInsight(
      data,
      EntryKind.water,
      'amount',
      'Hydration logging',
      'ml/day',
      currentStart,
      currentEnd,
      previousStart,
      previousEnd,
      true,
      insights,
      dailyAverage: true,
    );
    insights.sort((a, b) {
      final strengthA = _changeFromEvidence(a.evidence).abs() * a.confidence;
      final strengthB = _changeFromEvidence(b.evidence).abs() * b.confidence;
      return strengthB.compareTo(strengthA);
    });
    return insights;
  }

  void _measurementInsight(
    WellnessData data,
    MeasurementType type,
    String title,
    String unit,
    DateTime currentStart,
    DateTime currentEnd,
    DateTime previousStart,
    DateTime previousEnd,
    bool higherIsGenerallyBetter,
    List<LongitudinalInsight> into, {
    bool totalsByDay = false,
  }) {
    final current = _measurementDailyValues(
      data,
      type,
      currentStart,
      currentEnd,
      totalsByDay,
    );
    final previous = _measurementDailyValues(
      data,
      type,
      previousStart,
      previousEnd,
      totalsByDay,
    );
    _append(title, unit, current, previous, higherIsGenerallyBetter, into);
  }

  void _entryInsight(
    WellnessData data,
    EntryKind kind,
    String field,
    String title,
    String unit,
    DateTime currentStart,
    DateTime currentEnd,
    DateTime previousStart,
    DateTime previousEnd,
    bool higherIsGenerallyBetter,
    List<LongitudinalInsight> into, {
    bool dailyAverage = false,
  }) {
    final current = _entryDailyValues(
      data,
      kind,
      field,
      currentStart,
      currentEnd,
    );
    final previous = _entryDailyValues(
      data,
      kind,
      field,
      previousStart,
      previousEnd,
    );
    _append(
      title,
      unit,
      dailyAverage ? current : [current.fold(0, (a, b) => a + b)],
      dailyAverage ? previous : [previous.fold(0, (a, b) => a + b)],
      higherIsGenerallyBetter,
      into,
      sampleDays: current.length,
      previousSampleDays: previous.length,
    );
  }

  void _append(
    String title,
    String unit,
    List<double> current,
    List<double> previous,
    bool higherIsGenerallyBetter,
    List<LongitudinalInsight> into, {
    int? sampleDays,
    int? previousSampleDays,
  }) {
    final currentDays = sampleDays ?? current.length;
    final priorDays = previousSampleDays ?? previous.length;
    if (currentDays < 4 ||
        priorDays < 4 ||
        current.isEmpty ||
        previous.isEmpty) {
      return;
    }
    final now = _average(current);
    final before = _average(previous);
    if (before == 0) return;
    final change = (now - before) / before * 100;
    final stable = change.abs() < 5;
    final favourable = higherIsGenerallyBetter ? change > 0 : change < 0;
    final direction = stable
        ? InsightDirection.stable
        : favourable
        ? InsightDirection.improving
        : InsightDirection.declining;
    final confidence = ((currentDays + priorDays) / 20).clamp(.4, 1).toDouble();
    into.add(
      LongitudinalInsight(
        title: title,
        summary: stable
            ? '$title remained broadly stable.'
            : '$title ${change > 0 ? 'increased' : 'decreased'} by ${change.abs().toStringAsFixed(0)}%.',
        evidence:
            '${now.toStringAsFixed(now >= 100 ? 0 : 1)} $unit vs ${before.toStringAsFixed(before >= 100 ? 0 : 1)} $unit · change ${change.toStringAsFixed(1)}%',
        direction: direction,
        confidence: confidence,
        sampleDays: currentDays + priorDays,
      ),
    );
  }

  List<double> _measurementDailyValues(
    WellnessData data,
    MeasurementType type,
    DateTime start,
    DateTime end,
    bool total,
  ) {
    final grouped = <String, List<double>>{};
    for (final item in data.measurements) {
      if (item.measurementType != type ||
          item.recordedAt.isBefore(start) ||
          item.recordedAt.isAfter(end)) {
        continue;
      }
      grouped.putIfAbsent(_key(item.recordedAt), () => []).add(item.value);
    }
    return [
      for (final values in grouped.values)
        total ? values.fold(0, (a, b) => a + b) : _average(values),
    ];
  }

  List<double> _entryDailyValues(
    WellnessData data,
    EntryKind kind,
    String field,
    DateTime start,
    DateTime end,
  ) {
    final grouped = <String, double>{};
    for (final item in data.entries) {
      if (item.kind != kind ||
          item.recordedAt.isBefore(start) ||
          item.recordedAt.isAfter(end)) {
        continue;
      }
      grouped.update(
        _key(item.recordedAt),
        (value) => value + item.number(field),
        ifAbsent: () => item.number(field),
      );
    }
    return grouped.values.toList();
  }

  double _average(List<double> values) =>
      values.fold(0.0, (sum, value) => sum + value) / values.length;
  String _key(DateTime value) => '${value.year}-${value.month}-${value.day}';
  double _changeFromEvidence(String evidence) {
    final match = RegExp(r'change (-?[\d.]+)%').firstMatch(evidence);
    return double.tryParse(match?.group(1) ?? '') ?? 0;
  }
}
