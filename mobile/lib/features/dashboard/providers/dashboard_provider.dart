import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../health/models/health_measurement.dart';

enum TrendPeriod { day, week, month, year }

class TrendSelection {
  const TrendSelection({
    this.type = MeasurementType.heartRate,
    this.period = TrendPeriod.week,
  });
  final MeasurementType type;
  final TrendPeriod period;
}

class TrendController extends Notifier<TrendSelection> {
  @override
  TrendSelection build() => const TrendSelection();
  void selectType(MeasurementType type) =>
      state = TrendSelection(type: type, period: state.period);
  void selectPeriod(TrendPeriod period) =>
      state = TrendSelection(type: state.type, period: period);
}

final trendProvider = NotifierProvider<TrendController, TrendSelection>(
  TrendController.new,
);
List<HealthMeasurement> filterTrend(
  List<HealthMeasurement> values,
  TrendSelection selection,
  DateTime now,
) {
  final today = DateTime(now.year, now.month, now.day);
  final start = switch (selection.period) {
    TrendPeriod.day => today,
    TrendPeriod.week => today.subtract(const Duration(days: 6)),
    TrendPeriod.month => DateTime(now.year, now.month),
    TrendPeriod.year => DateTime(now.year),
  };
  return values
      .where(
        (m) =>
            m.measurementType == selection.type &&
            !m.recordedAt.isBefore(start) &&
            !m.recordedAt.isAfter(now),
      )
      .toList()
    ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
}
