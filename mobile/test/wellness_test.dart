import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/auth/providers/auth_provider.dart';
import 'package:telomy/features/journal/providers/wellness_provider.dart';
import 'package:telomy/features/journal/models/wellness_data.dart';
import 'package:telomy/features/journal/models/journal_entry.dart';
import 'package:telomy/features/journal/data/wellness_analytics.dart';
import 'package:telomy/features/devices/data/ring_snapshot.dart';
import 'package:telomy/features/health/models/health_measurement.dart';
import 'widget_test.dart' show MemoryTokens;
import 'wellness_test_support.dart';

void main() {
  test(
    'concurrent edits persist and failed writes do not change visible state',
    () async {
      final repo = MemoryWellnessRepository();
      final c = ProviderContainer(
        overrides: [
          tokenStorageProvider.overrideWithValue(
            MemoryTokens()..access = 'telomy-demo-session',
          ),
          wellnessRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(c.dispose);
      await c.read(authProvider.future);
      await c.read(wellnessProvider.future);
      final controller = c.read(wellnessProvider.notifier);
      await Future.wait([
        controller.saveEntry(
          JournalEntry.create(
            kind: EntryKind.meal,
            title: 'Lunch',
            recordedAt: DateTime.now(),
            fields: {'calories': '500'},
          ),
        ),
        controller.saveEntry(
          JournalEntry.create(
            kind: EntryKind.water,
            title: 'Water',
            recordedAt: DateTime.now(),
            fields: {'amount': '250'},
          ),
        ),
      ]);
      expect(repo.data.entries.length, 2);
      repo.failSave = true;
      await expectLater(
        controller.saveProfile({'fullName': 'New name'}),
        throwsStateError,
      );
      expect(c.read(wellnessProvider).asData!.value.profile, isEmpty);
      repo.failSave = false;
      await controller.saveProfile({'fullName': 'Saved name'});
      expect((await repo.load()).profile['fullName'], 'Saved name');
    },
  );
  test('live ring parser excludes invalid data and preserves source', () {
    final at = DateTime(2026, 9, 8, 12);
    final values = liveRingMeasurements(
      {'heartRate': 74, 'steps': 1000, 'spo2': 98},
      userId: 'u',
      deviceId: 'ring',
      observedAt: at,
    );
    expect(values.length, 2);
    expect(
      values.every(
        (m) =>
            m.source == MeasurementSource.wearable &&
            m.userId == 'u' &&
            m.recordedAt == at,
      ),
      true,
    );
    expect(
      liveRingMeasurements(
        {'heartRate': 0, 'steps': -1},
        userId: 'u',
        deviceId: 'ring',
        observedAt: at,
      ),
      isEmpty,
    );
  });
  test(
    'daily cumulative steps are not double counted and record roundtrip preserves subevents',
    () {
      final at = DateTime(2026, 9, 8, 12);
      final values = [
        ...liveRingMeasurements(
          {'steps': 100},
          userId: 'u',
          deviceId: 'ring',
          observedAt: at,
        ),
        ...liveRingMeasurements(
          {'steps': 200},
          userId: 'u',
          deviceId: 'ring',
          observedAt: at.add(const Duration(minutes: 5)),
        ),
      ];
      final entry = JournalEntry.create(
        kind: EntryKind.event,
        title: 'Cooldown',
        recordedAt: at,
        parentId: 'parent',
      );
      final d = WellnessData.fromJson(
        WellnessData(measurements: values, entries: [entry]).toJson(),
      );
      expect(d.entries.single.parentId, 'parent');
      expect(
        WellnessAnalytics(
          d,
          DateTime(2026, 9, 8),
          DateTime(2026, 9, 9),
        ).totalSteps,
        200,
      );
    },
  );
}
