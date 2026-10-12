import 'package:flutter/foundation.dart';

/// One day's air and sun where somebody was, as the server recorded it.
///
/// Every field is somebody else's measurement, which is why [provider] is
/// carried rather than assumed: "the AQI was 180" is a claim a third party
/// made, and the user is entitled to know who made it.
@immutable
class EnvironmentSnapshot {
  const EnvironmentSnapshot({
    required this.observedOn,
    required this.usAqiMean,
    required this.usAqiMax,
    required this.usAqiBand,
    required this.pm25Mean,
    required this.uvIndexMax,
    required this.uvBand,
    required this.hoursObserved,
    required this.provider,
  });

  final DateTime? observedOn;

  final double? usAqiMean;

  /// The day's peak. The band is taken from this rather than the average:
  /// three hours at 180 is the thing worth saying about the day.
  final double? usAqiMax;
  final String? usAqiBand;

  final double? pm25Mean;

  /// The day's peak, which is the only UV figure worth anything — it is 0 at
  /// night by definition.
  final double? uvIndexMax;
  final String? uvBand;

  /// How much of the day the provider had. Below 24 and this is not a day.
  final int hoursObserved;

  final String provider;

  bool get isPartialDay => hoursObserved > 0 && hoursObserved < 24;

  static double? _number(Object? value) =>
      value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');

  static EnvironmentSnapshot fromRow(Map<String, dynamic> row) =>
      EnvironmentSnapshot(
        observedOn: DateTime.tryParse(row['observed_on']?.toString() ?? ''),
        usAqiMean: _number(row['us_aqi_mean']),
        usAqiMax: _number(row['us_aqi_max']),
        usAqiBand: row['us_aqi_band']?.toString(),
        pm25Mean: _number(row['pm2_5_mean']),
        uvIndexMax: _number(row['uv_index_max']),
        uvBand: row['uv_band']?.toString(),
        hoursObserved: (row['hours_observed'] as num?)?.toInt() ?? 0,
        provider: row['provider']?.toString() ?? 'unknown',
      );
}
