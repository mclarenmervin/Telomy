import '../../health/models/health_measurement.dart';
import '../../journal/models/wellness_data.dart';

class BiologicalAgeFactor {
  const BiologicalAgeFactor({
    required this.name,
    required this.adjustment,
    required this.detail,
  });
  final String name, detail;
  final double adjustment;
}

class BiologicalAgeResult {
  const BiologicalAgeResult({
    required this.chronologicalAge,
    required this.estimatedAge,
    required this.confidence,
    required this.factors,
    required this.missingInputs,
    required this.version,
  });
  final int? chronologicalAge;
  final double? estimatedAge, confidence;
  final List<BiologicalAgeFactor> factors;
  final List<String> missingInputs;
  final String version;
}

class BiologicalAgeService {
  const BiologicalAgeService();
  static const version = 'biological-age-v1.0.0';

  BiologicalAgeResult calculate({
    required WellnessData data,
    required List<HealthMeasurement> measurements,
    required DateTime date,
  }) {
    final birthDate = DateTime.tryParse(data.profile['dob'] ?? '');
    final age = birthDate == null ? null : _ageAt(birthDate, date);
    final factors = <BiologicalAgeFactor>[];
    final missing = <String>[];
    final from = date.subtract(const Duration(days: 30));
    final recent = measurements
        .where(
          (item) =>
              !item.recordedAt.isBefore(from) && !item.recordedAt.isAfter(date),
        )
        .toList();

    final restingHeartRate = _average(recent, MeasurementType.restingHeartRate);
    if (restingHeartRate == null) {
      missing.add('Resting heart rate');
    } else {
      factors.add(
        BiologicalAgeFactor(
          name: 'Resting heart rate',
          adjustment: ((restingHeartRate - 65) / 8).clamp(-2.5, 3).toDouble(),
          detail: '${restingHeartRate.toStringAsFixed(0)} bpm 30-day average',
        ),
      );
    }

    final sleep = _dailyAverage(recent, MeasurementType.sleep);
    if (sleep == null) {
      missing.add('Sleep');
    } else {
      factors.add(
        BiologicalAgeFactor(
          name: 'Sleep',
          adjustment: ((7.5 - sleep).abs() * 1.2 - .8).clamp(-1, 3).toDouble(),
          detail: '${sleep.toStringAsFixed(1)} hours nightly average',
        ),
      );
    }

    final steps = _dailyAverage(recent, MeasurementType.steps);
    if (steps == null) {
      missing.add('Steps');
    } else {
      factors.add(
        BiologicalAgeFactor(
          name: 'Daily movement',
          adjustment: ((7000 - steps) / 2500).clamp(-2, 3).toDouble(),
          detail: '${steps.round()} steps daily average',
        ),
      );
    }

    final bmi = _latest(recent, MeasurementType.bmi) ?? _profileBmi(data);
    if (bmi == null) {
      missing.add('BMI');
    } else {
      final distance = bmi < 18.5
          ? 18.5 - bmi
          : bmi > 25
          ? bmi - 25
          : 0.0;
      factors.add(
        BiologicalAgeFactor(
          name: 'Body composition',
          adjustment: (distance * .45 - .5).clamp(-.5, 3).toDouble(),
          detail: 'BMI ${bmi.toStringAsFixed(1)}',
        ),
      );
    }

    final hrv = _average(recent, MeasurementType.hrv);
    if (hrv == null) {
      missing.add('HRV');
    } else {
      factors.add(
        BiologicalAgeFactor(
          name: 'HRV',
          adjustment: ((45 - hrv) / 15).clamp(-2, 3).toDouble(),
          detail: '${hrv.toStringAsFixed(0)} ms 30-day average',
        ),
      );
    }

    final confidence = age == null ? null : factors.length / 5;
    final estimate = age == null || factors.length < 3
        ? null
        : (age + factors.fold<double>(0, (sum, item) => sum + item.adjustment))
              .clamp(age - 10, age + 10)
              .toDouble();
    if (age == null) missing.insert(0, 'Date of birth');
    return BiologicalAgeResult(
      chronologicalAge: age,
      estimatedAge: estimate,
      confidence: confidence,
      factors: factors,
      missingInputs: missing,
      version: version,
    );
  }

  int _ageAt(DateTime birthDate, DateTime date) =>
      date.year -
      birthDate.year -
      (date.month < birthDate.month ||
              date.month == birthDate.month && date.day < birthDate.day
          ? 1
          : 0);

  double? _average(List<HealthMeasurement> values, MeasurementType type) {
    final matches = values
        .where((item) => item.measurementType == type)
        .toList();
    return matches.isEmpty
        ? null
        : matches.fold<double>(0, (sum, item) => sum + item.value) /
              matches.length;
  }

  double? _dailyAverage(List<HealthMeasurement> values, MeasurementType type) {
    final totals = <String, double>{};
    for (final item in values.where((item) => item.measurementType == type)) {
      final key =
          '${item.recordedAt.year}-${item.recordedAt.month}-${item.recordedAt.day}';
      totals.update(
        key,
        (value) => value + item.value,
        ifAbsent: () => item.value,
      );
    }
    return totals.isEmpty
        ? null
        : totals.values.fold<double>(0, (sum, value) => sum + value) /
              totals.length;
  }

  double? _latest(List<HealthMeasurement> values, MeasurementType type) {
    final matches =
        values.where((item) => item.measurementType == type).toList()
          ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    return matches.isEmpty ? null : matches.first.value;
  }

  double? _profileBmi(WellnessData data) {
    final height = double.tryParse(data.profile['height'] ?? '');
    final weight = double.tryParse(data.profile['weight'] ?? '');
    return height == null || height <= 0 || weight == null
        ? null
        : weight / ((height / 100) * (height / 100));
  }
}
