import 'dart:math' as math;
import '../../health/models/health_measurement.dart';
import '../../journal/models/journal_entry.dart';
import '../../journal/models/wellness_data.dart';

class CorrelationResult {
  const CorrelationResult({
    required this.first,
    required this.second,
    required this.coefficient,
    required this.sampleDays,
  });
  final String first, second;
  final double coefficient;
  final int sampleDays;

  String get strength {
    final value = coefficient.abs();
    return value >= .7
        ? 'Strong'
        : value >= .45
        ? 'Moderate'
        : 'Weak';
  }

  String get direction =>
      coefficient >= 0 ? 'move together' : 'move oppositely';
}

class CorrelationService {
  const CorrelationService();

  List<CorrelationResult> calculate(WellnessData data, {int days = 90}) {
    final end = DateTime.now();
    final start = DateTime(
      end.year,
      end.month,
      end.day,
    ).subtract(Duration(days: days - 1));
    final series = <String, Map<String, double>>{
      'Sleep': _measurementSeries(
        data,
        MeasurementType.sleep,
        start,
        total: true,
      ),
      'Steps': _measurementSeries(
        data,
        MeasurementType.steps,
        start,
        total: true,
      ),
      'Active minutes': _measurementSeries(
        data,
        MeasurementType.activity,
        start,
        total: true,
      ),
      'Resting heart rate': _measurementSeries(
        data,
        MeasurementType.restingHeartRate,
        start,
      ),
      'HRV': _measurementSeries(data, MeasurementType.hrv, start),
      'Stress': _measurementSeries(data, MeasurementType.stress, start),
      'Food energy': _entrySeries(data, EntryKind.meal, 'calories', start),
      'Protein': _entrySeries(data, EntryKind.meal, 'protein', start),
      'Hydration': _entrySeries(data, EntryKind.water, 'amount', start),
      'Workout minutes': _entrySeries(
        data,
        EntryKind.workout,
        'duration',
        start,
      ),
    };
    series.removeWhere((_, values) => values.length < 5);
    final names = series.keys.toList();
    final results = <CorrelationResult>[];
    for (var first = 0; first < names.length; first++) {
      for (var second = first + 1; second < names.length; second++) {
        final firstValues = series[names[first]]!;
        final secondValues = series[names[second]]!;
        final common = firstValues.keys
            .where(secondValues.containsKey)
            .toList();
        if (common.length < 5) continue;
        final coefficient = _pearson(
          [for (final day in common) firstValues[day]!],
          [for (final day in common) secondValues[day]!],
        );
        if (coefficient == null) continue;
        results.add(
          CorrelationResult(
            first: names[first],
            second: names[second],
            coefficient: coefficient,
            sampleDays: common.length,
          ),
        );
      }
    }
    results.sort((a, b) => b.coefficient.abs().compareTo(a.coefficient.abs()));
    return results;
  }

  Map<String, double> _measurementSeries(
    WellnessData data,
    MeasurementType type,
    DateTime start, {
    bool total = false,
  }) {
    final values = <String, List<double>>{};
    for (final item in data.measurements) {
      if (item.measurementType != type || item.recordedAt.isBefore(start)) {
        continue;
      }
      values.putIfAbsent(_key(item.recordedAt), () => []).add(item.value);
    }
    return {
      for (final item in values.entries)
        item.key: total
            ? item.value.fold<double>(0, (sum, value) => sum + value)
            : item.value.fold<double>(0, (sum, value) => sum + value) /
                  item.value.length,
    };
  }

  Map<String, double> _entrySeries(
    WellnessData data,
    EntryKind kind,
    String field,
    DateTime start,
  ) {
    final values = <String, double>{};
    for (final entry in data.entries) {
      if (entry.kind != kind || entry.recordedAt.isBefore(start)) continue;
      values.update(
        _key(entry.recordedAt),
        (value) => value + entry.number(field),
        ifAbsent: () => entry.number(field),
      );
    }
    return values;
  }

  double? _pearson(List<double> first, List<double> second) {
    final firstMean = first.reduce((a, b) => a + b) / first.length;
    final secondMean = second.reduce((a, b) => a + b) / second.length;
    var numerator = 0.0, firstSquares = 0.0, secondSquares = 0.0;
    for (var index = 0; index < first.length; index++) {
      final a = first[index] - firstMean;
      final b = second[index] - secondMean;
      numerator += a * b;
      firstSquares += a * a;
      secondSquares += b * b;
    }
    final denominator = math.sqrt(firstSquares * secondSquares);
    return denominator == 0 ? null : numerator / denominator;
  }

  String _key(DateTime value) => '${value.year}-${value.month}-${value.day}';
}
