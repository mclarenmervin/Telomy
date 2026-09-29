import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../auth/providers/auth_provider.dart';
import '../../journal/providers/wellness_provider.dart';
import '../data/platform_health_adapter.dart';
import '../models/health_measurement.dart';

class PlatformHealthState {
  const PlatformHealthState({this.busy = false, this.message, this.error});
  final bool busy;
  final String? message;
  final String? error;
}

final platformHealthProvider =
    NotifierProvider<PlatformHealthController, PlatformHealthState>(
      PlatformHealthController.new,
    );

class PlatformHealthController extends Notifier<PlatformHealthState> {
  static const types = <MeasurementType>{
    MeasurementType.heartRate,
    MeasurementType.restingHeartRate,
    MeasurementType.hrv,
    MeasurementType.spo2,
    MeasurementType.temperature,
    MeasurementType.respiratoryRate,
    MeasurementType.weight,
    MeasurementType.bmi,
    MeasurementType.sleep,
    MeasurementType.sleepInBed,
    MeasurementType.sleepLight,
    MeasurementType.sleepDeep,
    MeasurementType.sleepRem,
    MeasurementType.sleepAwake,
    MeasurementType.steps,
    MeasurementType.calories,
    MeasurementType.distance,
    MeasurementType.activity,
    MeasurementType.bodyFat,
    MeasurementType.muscleMass,
    MeasurementType.waistCircumference,
  };

  @override
  PlatformHealthState build() => const PlatformHealthState();

  PlatformHealthAdapter _adapter() {
    final user = ref.read(authProvider).asData?.value;
    if (user == null) throw StateError('Sign in to connect health data.');
    if (Platform.isIOS) return AppleHealthAdapter(user.id);
    if (Platform.isAndroid) return HealthConnectAdapter(user.id);
    throw UnsupportedError('Health data is available on iOS and Android.');
  }

  String get _consentKey =>
      Platform.isIOS ? 'consentAppleHealth' : 'consentHealthConnect';

  Future<void> connectAndSync() async {
    if (state.busy) return;
    state = const PlatformHealthState(
      busy: true,
      message: 'Requesting health access…',
    );
    try {
      final adapter = _adapter();
      if (!await adapter.isAvailable()) {
        throw StateError(
          Platform.isAndroid
              ? 'Health Connect is not available on this device.'
              : 'Apple Health is not available on this device.',
        );
      }
      if (Platform.isAndroid) {
        final activity = await Permission.activityRecognition.request();
        if (!activity.isGranted) {
          throw StateError('Activity permission is required to import steps.');
        }
      }
      if (!await adapter.requestAccess(types)) {
        throw StateError(
          'Health access was not granted. You can change it in system settings.',
        );
      }
      final current = ref.read(wellnessProvider).asData?.value;
      if (current == null) throw StateError('Health profile is still loading.');
      await ref.read(wellnessProvider.notifier).saveProfile({
        ...current.profile,
        _consentKey: 'true',
      });
      await _sync(adapter);
    } catch (error) {
      state = PlatformHealthState(error: _message(error));
    }
  }

  Future<void> sync() async {
    if (state.busy) return;
    state = const PlatformHealthState(
      busy: true,
      message: 'Importing health records…',
    );
    try {
      await _sync(_adapter());
    } catch (error) {
      state = PlatformHealthState(error: _message(error));
    }
  }

  Future<void> _sync(PlatformHealthAdapter adapter) async {
    final now = DateTime.now();
    final values = await adapter.importMeasurements(
      from: now.subtract(const Duration(days: 30)),
      to: now,
      types: types,
    );
    await ref.read(wellnessProvider.notifier).addMeasurements(values);
    final current = ref.read(wellnessProvider).asData?.value;
    if (current != null) {
      await ref.read(wellnessProvider.notifier).saveProfile({
        ...current.profile,
        '${_consentKey}LastSync': now.toIso8601String(),
      });
    }
    state = PlatformHealthState(
      message: values.isEmpty
          ? 'Connected. No supported records were found in the last 30 days.'
          : 'Imported ${values.length} health records.',
    );
  }

  Future<void> disconnect() async {
    if (state.busy) return;
    state = const PlatformHealthState(
      busy: true,
      message: 'Revoking health access…',
    );
    try {
      await _adapter().disconnect();
      final current = ref.read(wellnessProvider).asData?.value;
      if (current != null) {
        await ref.read(wellnessProvider.notifier).saveProfile({
          ...current.profile,
          _consentKey: 'false',
        });
      }
      state = const PlatformHealthState(message: 'Health access revoked.');
    } catch (error) {
      state = PlatformHealthState(error: _message(error));
    }
  }

  String _message(Object error) => switch (error) {
    StateError e => e.message.toString(),
    UnsupportedError e => e.message.toString(),
    _ =>
      'Health data could not be accessed. Check system permissions and retry.',
  };
}
