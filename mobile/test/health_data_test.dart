import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/health/data/mock_health_repository.dart';
import 'package:telomy/features/health/models/health_measurement.dart';
import 'package:telomy/features/dashboard/providers/dashboard_provider.dart';

void main() {
  test(
    'mock data is timestamped, user scoped, and filters calendar periods',
    () async {
      final now = DateTime(2026, 9, 3, 12);
      final data = await MockHealthRepository(
        now: () => now,
      ).getMeasurements(userId: 'user-1');
      expect(data.length, 70);
      expect(data.map((m) => m.id).toSet().length, 70);
      expect(data.every((m) => m.userId == 'user-1'), isTrue);
      expect(
        filterTrend(
          data,
          const TrendSelection(period: TrendPeriod.day),
          now,
        ).length,
        1,
      );
      expect(filterTrend(data, const TrendSelection(), now).length, 7);
      expect(
        filterTrend(
          data,
          const TrendSelection(period: TrendPeriod.month),
          now,
        ).length,
        3,
      );
      expect(
        data.where((m) => m.measurementType == MeasurementType.sleep).length,
        7,
      );
    },
  );
}
