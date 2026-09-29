import '../models/health_measurement.dart';
import 'health_repository.dart';

class MockHealthRepository implements HealthRepository {
  MockHealthRepository({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  @override
  Future<List<HealthMeasurement>> getMeasurements({
    required String userId,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final now = _now();
    final today = DateTime(now.year, now.month, now.day);
    final series = <MeasurementType, (String, List<double>)>{
      MeasurementType.heartRate: ('BPM', [72, 75, 71, 76, 73, 72, 74]),
      MeasurementType.steps: (
        'steps',
        [6200, 9100, 7400, 8100, 6900, 8650, 7840],
      ),
      MeasurementType.sleep: ('h', [6.8, 7.2, 7.7, 6.9, 8.1, 7.4, 7 + 35 / 60]),
      MeasurementType.stress: ('/100', [38, 46, 35, 52, 32, 40, 44]),
      MeasurementType.weight: (
        'kg',
        [72.8, 72.6, 72.7, 72.5, 72.4, 72.5, 72.4],
      ),
      MeasurementType.spo2: ('%', [98, 98, 99, 98, 97, 98, 98]),
      MeasurementType.bloodPressure: (
        'mmHg',
        [118, 121, 119, 122, 118, 119, 120],
      ),
      MeasurementType.temperature: (
        '°C',
        [36.5, 36.6, 36.7, 36.6, 36.8, 36.6, 36.7],
      ),
      MeasurementType.activity: ('min', [25, 42, 30, 35, 20, 48, 36]),
      MeasurementType.calories: ('kcal', [280, 410, 320, 360, 240, 460, 385]),
    };
    return [
      for (final entry in series.entries)
        for (var i = 0; i < 7; i++)
          HealthMeasurement(
            id: '00000000-0000-4000-8000-${(entry.key.index * 7 + i + 1).toString().padLeft(12, '0')}',
            userId: userId,
            measurementType: entry.key,
            value: entry.value.$2[i],
            unit: entry.value.$1,
            recordedAt: today.subtract(Duration(days: 6 - i)),
            source: MeasurementSource.manual,
            secondaryValue: entry.key == MeasurementType.bloodPressure
                ? 80
                : null,
          ),
    ];
  }
}
