import 'dart:io';
import 'package:health/health.dart';
import '../models/health_measurement.dart';
import '../../devices/data/health_data_source.dart';

abstract base class PlatformHealthAdapter implements HealthDataSource {
  PlatformHealthAdapter(this.userId, this._source);

  final String userId;
  final MeasurementSource _source;
  final Health _health = Health();
  bool _configured = false;

  Future<void> _configure() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  List<HealthDataType> _nativeTypes(Set<MeasurementType> requested) =>
      requested.map(_healthType).whereType<HealthDataType>().toSet().toList();

  HealthDataType? _healthType(MeasurementType type) => switch (type) {
    MeasurementType.heartRate => HealthDataType.HEART_RATE,
    MeasurementType.restingHeartRate => HealthDataType.RESTING_HEART_RATE,
    MeasurementType.hrv =>
      Platform.isAndroid
          ? HealthDataType.HEART_RATE_VARIABILITY_RMSSD
          : HealthDataType.HEART_RATE_VARIABILITY_SDNN,
    MeasurementType.spo2 => HealthDataType.BLOOD_OXYGEN,
    MeasurementType.temperature => HealthDataType.BODY_TEMPERATURE,
    MeasurementType.respiratoryRate => HealthDataType.RESPIRATORY_RATE,
    MeasurementType.weight => HealthDataType.WEIGHT,
    MeasurementType.bmi => HealthDataType.BODY_MASS_INDEX,
    MeasurementType.sleep => HealthDataType.SLEEP_ASLEEP,
    MeasurementType.sleepInBed =>
      Platform.isAndroid ? null : HealthDataType.SLEEP_IN_BED,
    MeasurementType.sleepLight => HealthDataType.SLEEP_LIGHT,
    MeasurementType.sleepDeep => HealthDataType.SLEEP_DEEP,
    MeasurementType.sleepRem => HealthDataType.SLEEP_REM,
    MeasurementType.sleepAwake => HealthDataType.SLEEP_AWAKE,
    MeasurementType.activity =>
      Platform.isAndroid ? null : HealthDataType.EXERCISE_TIME,
    MeasurementType.steps => HealthDataType.STEPS,
    MeasurementType.calories => HealthDataType.ACTIVE_ENERGY_BURNED,
    MeasurementType.distance =>
      Platform.isAndroid
          ? HealthDataType.DISTANCE_DELTA
          : HealthDataType.DISTANCE_WALKING_RUNNING,
    MeasurementType.bodyFat => HealthDataType.BODY_FAT_PERCENTAGE,
    MeasurementType.muscleMass => HealthDataType.LEAN_BODY_MASS,
    MeasurementType.waistCircumference =>
      Platform.isAndroid ? null : HealthDataType.WAIST_CIRCUMFERENCE,
    _ => null,
  };

  @override
  Future<bool> requestAccess(Set<MeasurementType> types) async {
    await _configure();
    final native = _nativeTypes(types);
    return native.isNotEmpty && await _health.requestAuthorization(native);
  }

  Future<List<HealthMeasurement>> importMeasurements({
    required DateTime from,
    required DateTime to,
    required Set<MeasurementType> types,
  }) async {
    await _configure();
    final native = _nativeTypes(types);
    if (native.isEmpty) return const [];
    final points = _health.removeDuplicates(
      await _health.getHealthDataFromTypes(
        types: native,
        startTime: from,
        endTime: to,
      ),
    );
    return points.map(_normalize).whereType<HealthMeasurement>().toList()
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
  }

  HealthMeasurement? _normalize(HealthDataPoint point) {
    final value = point.value;
    if (value is! NumericHealthValue || !value.numericValue.isFinite) {
      return null;
    }
    final metric = _metricType(point.type);
    if (metric == null) return null;
    var amount = value.numericValue.toDouble();
    var unit = _unit(metric);
    if ({
      MeasurementType.sleep,
      MeasurementType.sleepInBed,
      MeasurementType.sleepLight,
      MeasurementType.sleepDeep,
      MeasurementType.sleepRem,
      MeasurementType.sleepAwake,
    }.contains(metric)) {
      amount = point.dateTo.difference(point.dateFrom).inMinutes / 60;
      unit = 'h';
    }
    if (metric == MeasurementType.distance) {
      amount /= 1000;
      unit = 'km';
    }
    if (metric == MeasurementType.waistCircumference) {
      amount *= 100;
      unit = 'cm';
    }
    return HealthMeasurement(
      id: '$sourceId:${point.uuid}:${metric.name}',
      userId: userId,
      measurementType: metric,
      value: amount,
      unit: unit,
      recordedAt: point.dateFrom,
      endedAt: point.dateTo,
      source: _source,
      deviceId: point.sourceDeviceId.isEmpty
          ? point.sourceId
          : point.sourceDeviceId,
      quality: point.recordingMethod == RecordingMethod.manual
          ? MeasurementQuality.unknown
          : MeasurementQuality.measured,
    );
  }

  MeasurementType? _metricType(HealthDataType type) {
    for (final metric in MeasurementType.values) {
      if (_healthType(metric) == type) return metric;
    }
    return null;
  }

  String _unit(MeasurementType type) => switch (type) {
    MeasurementType.heartRate || MeasurementType.restingHeartRate => 'BPM',
    MeasurementType.hrv => 'ms',
    MeasurementType.spo2 || MeasurementType.bodyFat => '%',
    MeasurementType.temperature => '°C',
    MeasurementType.respiratoryRate => '/min',
    MeasurementType.weight => 'kg',
    MeasurementType.muscleMass => 'kg',
    MeasurementType.bmi => 'kg/m²',
    MeasurementType.sleep ||
    MeasurementType.sleepInBed ||
    MeasurementType.sleepLight ||
    MeasurementType.sleepDeep ||
    MeasurementType.sleepRem ||
    MeasurementType.sleepAwake => 'h',
    MeasurementType.steps => 'steps',
    MeasurementType.calories => 'kcal',
    MeasurementType.distance => 'km',
    MeasurementType.activity => 'min',
    MeasurementType.waistCircumference => 'cm',
    _ => '',
  };

  @override
  Stream<List<HealthMeasurement>> read({
    required DateTime from,
    required DateTime to,
    required Set<MeasurementType> types,
  }) async* {
    yield await importMeasurements(from: from, to: to, types: types);
  }

  @override
  Future<void> disconnect() async {
    await _configure();
    await _health.revokePermissions();
  }
}

final class AppleHealthAdapter extends PlatformHealthAdapter {
  AppleHealthAdapter(String userId)
    : super(userId, MeasurementSource.healthkit);
  @override
  String get sourceId => 'apple_health';
  @override
  Future<bool> isAvailable() async => Platform.isIOS;
}

final class HealthConnectAdapter extends PlatformHealthAdapter {
  HealthConnectAdapter(String userId)
    : super(userId, MeasurementSource.googleHealthConnect);
  @override
  String get sourceId => 'health_connect';
  @override
  Future<bool> isAvailable() async {
    if (!Platform.isAndroid) return false;
    await _configure();
    return _health.isHealthConnectAvailable();
  }
}
