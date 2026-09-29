import '../../health/models/health_measurement.dart';

class BodyCompositionSummary {
  const BodyCompositionSummary({
    required this.weight,
    required this.bmi,
    required this.bodyFat,
    required this.muscleMass,
    required this.waist,
    required this.hip,
    required this.waistToHeight,
    required this.waistToHip,
  });
  final HealthMeasurement? weight;
  final double? bmi;
  final HealthMeasurement? bodyFat;
  final HealthMeasurement? muscleMass;
  final HealthMeasurement? waist;
  final HealthMeasurement? hip;
  final double? waistToHeight;
  final double? waistToHip;
}

class BodyCompositionAnalysis {
  const BodyCompositionAnalysis();

  BodyCompositionSummary summarize(
    List<HealthMeasurement> values,
    Map<String, String> profile,
  ) {
    final weight = _latest(values, MeasurementType.weight);
    final bodyFat = _latest(values, MeasurementType.bodyFat);
    final muscle = _latest(values, MeasurementType.muscleMass);
    final waist = _latest(values, MeasurementType.waistCircumference);
    final hip = _latest(values, MeasurementType.hipCircumference);
    final measuredBmi = _latest(values, MeasurementType.bmi)?.value;
    final height = double.tryParse(profile['height'] ?? '');
    final profileWaist = double.tryParse(profile['waist'] ?? '');
    final profileHip = double.tryParse(profile['hip'] ?? '');
    final waistValue = waist?.value ?? profileWaist;
    final hipValue = hip?.value ?? profileHip;
    final calculatedBmi = weight != null && height != null && height > 0
        ? weight.value / ((height / 100) * (height / 100))
        : null;
    return BodyCompositionSummary(
      weight: weight,
      bmi: measuredBmi ?? calculatedBmi,
      bodyFat: bodyFat,
      muscleMass: muscle,
      waist: waist,
      hip: hip,
      waistToHeight: waistValue != null && height != null && height > 0
          ? waistValue / height
          : null,
      waistToHip: waistValue != null && hipValue != null && hipValue > 0
          ? waistValue / hipValue
          : null,
    );
  }

  HealthMeasurement? _latest(
    List<HealthMeasurement> values,
    MeasurementType type,
  ) {
    final matches =
        values.where((value) => value.measurementType == type).toList()
          ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    return matches.isEmpty ? null : matches.last;
  }
}
