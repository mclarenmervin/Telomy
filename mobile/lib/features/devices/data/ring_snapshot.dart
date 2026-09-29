import 'package:uuid/uuid.dart';
import '../../health/models/health_measurement.dart';

/// Only live SDK callbacks have a known observation time. Undated vendor
/// history stays in the ring report and is not assigned invented timestamps.
List<HealthMeasurement> liveRingMeasurements(
  Map<String, dynamic> payload, {
  required String userId,
  required String deviceId,
  required DateTime observedAt,
}) {
  final result = <HealthMeasurement>[];
  for (final spec in [
    ('heartRate', MeasurementType.heartRate, 'BPM', 30.0, 240.0),
    ('steps', MeasurementType.steps, 'steps', 0.0, 200000.0),
  ]) {
    final n = payload[spec.$1];
    if (n is! num || !n.isFinite || n < spec.$4 || n > spec.$5) continue;
    result.add(
      HealthMeasurement(
        id: const Uuid().v4(),
        userId: userId,
        measurementType: spec.$2,
        value: n.toDouble(),
        unit: spec.$3,
        recordedAt: observedAt,
        source: MeasurementSource.wearable,
        deviceId: deviceId,
      ),
    );
  }
  return result;
}

/// Converts the vendor's fixed daily history arrays into durable health
/// measurements. The SDK defines 1,440 minute slots for heart/activity and 48
/// half-hour slots for SpO2, HRV and stress, so their timestamps are stable.
List<HealthMeasurement> storedRingMeasurements(
  Map<String, dynamic> payload, {
  required String userId,
  required String deviceId,
  required DateTime day,
}) {
  final records = Map<String, dynamic>.from(payload['records'] as Map? ?? {});
  final result = <HealthMeasurement>[];
  final start = DateTime(day.year, day.month, day.day);

  void addSeries(
    String key,
    MeasurementType type,
    String unit,
    Duration interval,
    double min,
    double max,
  ) {
    final values = (records[key] as List? ?? const []);
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value is! num || !value.isFinite || value < min || value > max) {
        continue;
      }
      final recordedAt = start.add(
        Duration(microseconds: interval.inMicroseconds * i),
      );
      result.add(
        HealthMeasurement(
          id: const Uuid().v4(),
          userId: userId,
          measurementType: type,
          value: value.toDouble(),
          unit: unit,
          recordedAt: recordedAt,
          source: MeasurementSource.wearable,
          deviceId: deviceId,
        ),
      );
    }
  }

  addSeries(
    'heartRate',
    MeasurementType.heartRate,
    'BPM',
    const Duration(minutes: 1),
    30,
    240,
  );
  addSeries(
    'spo2',
    MeasurementType.spo2,
    '%',
    const Duration(minutes: 30),
    70,
    100,
  );
  addSeries(
    'hrv',
    MeasurementType.hrv,
    'ms',
    const Duration(minutes: 30),
    1,
    250,
  );
  addSeries(
    'stress',
    MeasurementType.stress,
    'index',
    const Duration(minutes: 30),
    1,
    100,
  );

  final stepValues = (records['steps'] as List? ?? const []).whereType<num>();
  final steps = stepValues.fold<double>(0, (sum, value) => sum + value);
  if (steps > 0) {
    result.add(
      HealthMeasurement(
        id: const Uuid().v4(),
        userId: userId,
        measurementType: MeasurementType.steps,
        value: steps,
        unit: 'steps',
        recordedAt: start.add(const Duration(hours: 23, minutes: 59)),
        source: MeasurementSource.wearable,
        deviceId: deviceId,
      ),
    );
  }
  final sleepValues = (records['sleep'] as List? ?? const []).whereType<num>();
  final sleepMinutes = sleepValues.where((value) => value > 0).length;
  if (sleepMinutes > 0) {
    result.add(
      HealthMeasurement(
        id: const Uuid().v4(),
        userId: userId,
        measurementType: MeasurementType.sleep,
        value: sleepMinutes / 60,
        unit: 'hours',
        recordedAt: start,
        endedAt: start.add(Duration(minutes: sleepMinutes)),
        source: MeasurementSource.wearable,
        deviceId: deviceId,
      ),
    );
  }
  return result;
}
