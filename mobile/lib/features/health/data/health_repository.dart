import '../models/health_measurement.dart';

abstract interface class HealthRepository {
  Future<List<HealthMeasurement>> getMeasurements({required String userId});
}
