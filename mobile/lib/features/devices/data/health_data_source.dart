import '../../health/models/health_measurement.dart';

/// Future adapters request permissions only after explicit user action.
/// Implementations must paginate/batch readings and preserve source provenance.
abstract interface class HealthDataSource {
  String get sourceId;
  Future<bool> isAvailable();
  Future<bool> requestAccess(Set<MeasurementType> types);
  Stream<List<HealthMeasurement>> read({
    required DateTime from,
    required DateTime to,
    required Set<MeasurementType> types,
  });
  Future<void> disconnect();
}
