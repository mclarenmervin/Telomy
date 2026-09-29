import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../health/models/health_measurement.dart';

String metricLabel(MeasurementType type) => switch (type) {
  MeasurementType.heartRate => 'Heart rate',
  MeasurementType.spo2 => 'Blood oxygen',
  MeasurementType.bloodPressure => 'Blood pressure',
  MeasurementType.temperature => 'Temperature',
  MeasurementType.sleep => 'Sleep',
  MeasurementType.steps => 'Steps',
  MeasurementType.stress => 'Stress',
  MeasurementType.weight => 'Weight',
  MeasurementType.activity => 'Activity',
  MeasurementType.calories => 'Active calories',
  MeasurementType.bmi => 'BMI',
  MeasurementType.respiratoryRate => 'Respiratory rate',
  MeasurementType.restingHeartRate => 'Resting heart rate',
  MeasurementType.hrv => 'HRV',
  MeasurementType.distance => 'Distance',
  MeasurementType.sedentaryTime => 'Sedentary time',
  MeasurementType.bodyFat => 'Body fat',
  MeasurementType.muscleMass => 'Muscle mass',
  MeasurementType.sleepInBed => 'Time in bed',
  MeasurementType.sleepLight => 'Light sleep',
  MeasurementType.sleepDeep => 'Deep sleep',
  MeasurementType.sleepRem => 'REM sleep',
  MeasurementType.sleepAwake => 'Awake',
  MeasurementType.waistCircumference => 'Waist circumference',
  MeasurementType.hipCircumference => 'Hip circumference',
};
IconData metricIcon(MeasurementType type) => switch (type) {
  MeasurementType.heartRate => Icons.favorite_outline,
  MeasurementType.sleep ||
  MeasurementType.sleepInBed ||
  MeasurementType.sleepLight ||
  MeasurementType.sleepDeep ||
  MeasurementType.sleepRem ||
  MeasurementType.sleepAwake => Icons.bedtime_outlined,
  MeasurementType.steps => Icons.directions_walk,
  MeasurementType.stress => Icons.waves,
  MeasurementType.weight => Icons.monitor_weight_outlined,
  MeasurementType.temperature => Icons.thermostat,
  MeasurementType.spo2 => Icons.water_drop_outlined,
  MeasurementType.bloodPressure => Icons.monitor_heart_outlined,
  MeasurementType.waistCircumference ||
  MeasurementType.hipCircumference => Icons.straighten,
  _ => Icons.bolt_outlined,
};
String metricValue(HealthMeasurement m) {
  if (m.measurementType == MeasurementType.bloodPressure) {
    return '${m.value.round()}/${m.secondaryValue?.round() ?? '—'}';
  }
  if ({
    MeasurementType.sleep,
    MeasurementType.sleepInBed,
    MeasurementType.sleepLight,
    MeasurementType.sleepDeep,
    MeasurementType.sleepRem,
    MeasurementType.sleepAwake,
  }.contains(m.measurementType)) {
    final minutes = (m.value * 60).round();
    return '${minutes ~/ 60}h ${minutes % 60}m';
  }
  return NumberFormat(
    m.value == m.value.roundToDouble() ? '#,##0' : '#,##0.0',
  ).format(m.value);
}

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.measurement,
    this.previous,
    required this.onTap,
  });
  final HealthMeasurement measurement;
  final HealthMeasurement? previous;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final delta = previous == null || previous!.value == 0
        ? null
        : (measurement.value - previous!.value) / previous!.value * 100;
    final trend = delta == null
        ? 'No comparison'
        : delta.abs() < 0.05
        ? 'Stable'
        : '${delta > 0 ? '+' : ''}${delta.toStringAsFixed(1)}%';
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(
                metricIcon(measurement.measurementType),
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                metricLabel(measurement.measurementType),
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  metricValue(measurement),
                  style: theme.textTheme.headlineMedium,
                ),
              ),
              Text(measurement.unit, style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(
                '${measurement.quality.name} · ${measurement.source.name}',
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: 12),
              Text(
                '$trend vs previous reading',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
