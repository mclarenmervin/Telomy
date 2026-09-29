enum MeasurementSource { manual, wearable, healthkit, googleHealthConnect, api }

enum MeasurementType {
  heartRate,
  spo2,
  bloodPressure,
  temperature,
  respiratoryRate,
  weight,
  bmi,
  sleep,
  steps,
  activity,
  stress,
  calories,
  restingHeartRate,
  hrv,
  distance,
  sedentaryTime,
  bodyFat,
  muscleMass,
  sleepInBed,
  sleepLight,
  sleepDeep,
  sleepRem,
  sleepAwake,
  waistCircumference,
  hipCircumference,
}

enum MeasurementQuality { unknown, measured, estimated }

class HealthMeasurement {
  const HealthMeasurement({
    required this.id,
    required this.userId,
    required this.measurementType,
    required this.value,
    required this.unit,
    required this.recordedAt,
    required this.source,
    this.deviceId,
    this.secondaryValue,
    this.quality = MeasurementQuality.measured,
    this.endedAt,
  });
  final String id;
  final String userId;
  final MeasurementType measurementType;
  final double value;
  final double? secondaryValue;
  final String unit;
  final DateTime recordedAt;
  final MeasurementSource source;
  final String? deviceId;
  final MeasurementQuality quality;
  final DateTime? endedAt;
  factory HealthMeasurement.fromJson(Map<String, dynamic> json) =>
      HealthMeasurement(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        measurementType: MeasurementType.values.byName(
          json['measurement_type'] as String,
        ),
        value: (json['value'] as num).toDouble(),
        secondaryValue: (json['secondary_value'] as num?)?.toDouble(),
        unit: json['unit'] as String,
        recordedAt: DateTime.parse(json['recorded_at'] as String).toLocal(),
        source: json['source'] == 'google_health_connect'
            ? MeasurementSource.googleHealthConnect
            : MeasurementSource.values.byName(json['source'] as String),
        deviceId: json['device_id'] as String?,
        quality: MeasurementQuality.values.byName(
          json['quality'] as String? ?? 'measured',
        ),
        endedAt: json['ended_at'] == null
            ? null
            : DateTime.parse(json['ended_at'] as String).toLocal(),
      );
  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'measurement_type': measurementType.name,
    'value': value,
    'secondary_value': secondaryValue,
    'unit': unit,
    'recorded_at': recordedAt.toUtc().toIso8601String(),
    'source': source == MeasurementSource.googleHealthConnect
        ? 'google_health_connect'
        : source.name,
    'device_id': deviceId,
    'quality': quality.name,
    'ended_at': endedAt?.toUtc().toIso8601String(),
  };
}
