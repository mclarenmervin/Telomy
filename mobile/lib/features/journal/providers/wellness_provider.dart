import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/providers/auth_provider.dart';
import '../../health/models/health_measurement.dart';
import '../../health/data/mock_health_repository.dart';
import '../data/wellness_repository.dart';
import '../models/wellness_data.dart';
import '../models/journal_entry.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/config/supabase_config.dart';

final wellnessRepositoryProvider = Provider<WellnessRepository>((ref) {
  final user = ref.watch(authProvider).asData?.value;
  if (user == null) throw StateError('Sign in to access your records.');
  if (SupabaseConfig.configured) {
    return SupabaseWellnessRepository(user.id, Supabase.instance.client);
  }
  return SecureWellnessRepository(user.id);
});
final wellnessProvider =
    AsyncNotifierProvider<WellnessController, WellnessData>(
      WellnessController.new,
    );

class WellnessController extends AsyncNotifier<WellnessData> {
  Future<void> _queue = Future.value();
  @override
  Future<WellnessData> build() async {
    final user = ref.watch(authProvider).asData?.value;
    if (user == null) return const WellnessData();
    return ref.watch(wellnessRepositoryProvider).load();
  }

  Future<void> change(WellnessData Function(WellnessData) update) {
    final repository = ref.read(wellnessRepositoryProvider);
    final userId = ref.read(authProvider).asData?.value?.id;
    final next = _queue.catchError((Object _) {}).then((_) async {
      final current = state.asData?.value;
      if (current == null ||
          ref.read(authProvider).asData?.value?.id != userId) {
        throw StateError('Your session changed. Please retry.');
      }
      final value = update(current);
      await repository.save(value);
      if (ref.mounted && ref.read(authProvider).asData?.value?.id == userId) {
        state = AsyncData(value);
      }
    });
    _queue = next;
    return next;
  }

  Future<void> saveEntry(JournalEntry entry) => change(
    (d) => d.copyWith(
      entries: [...d.entries.where((e) => e.id != entry.id), entry],
    ),
  );
  Future<void> deleteEntry(String id) => change(
    (d) => d.copyWith(
      entries: d.entries.where((e) => e.id != id && e.parentId != id).toList(),
    ),
  );
  Future<void> saveProfile(Map<String, String> profile) =>
      change((d) => d.copyWith(profile: Map.unmodifiable(profile)));
  Future<void> addMeasurements(List<HealthMeasurement> values) => change((d) {
    final byKey = {for (final m in d.measurements) _measurementKey(m): m};
    for (final m in values) {
      byKey[_measurementKey(m)] = m;
    }
    return d.copyWith(
      measurements: byKey.values.toList()
        ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt)),
      demo: false,
    );
  });

  String _measurementKey(HealthMeasurement m) => [
    m.userId,
    m.measurementType.name,
    m.recordedAt.toUtc().microsecondsSinceEpoch,
    m.source.name,
    m.deviceId ?? '',
  ].join('|');
  Future<void> deleteMeasurement(String id) => change(
    (d) => d.copyWith(
      measurements: d.measurements.where((m) => m.id != id).toList(),
    ),
  );
  Future<void> saveRing(Map<String, dynamic> ring) =>
      change((d) => d.copyWith(ring: Map.unmodifiable(ring)));
  Future<void> setDemo(bool enabled) async {
    final user = ref.read(authProvider).asData?.value;
    if (user == null) return;
    // Preview data is never persisted alongside personal readings.
    await change((d) => d.copyWith(demo: enabled));
  }

  Future<void> clearPersonalData() => change((_) => const WellnessData());
}

final displayedMeasurementsProvider = FutureProvider<List<HealthMeasurement>>((
  ref,
) async {
  final data = await ref.watch(wellnessProvider.future);
  final user = ref.watch(authProvider).asData?.value;
  if (data.demo && user != null) {
    return MockHealthRepository().getMeasurements(userId: user.id);
  }
  return data.measurements;
});
