import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../auth/providers/auth_provider.dart';
import '../../journal/providers/wellness_provider.dart';
import '../data/ring_snapshot.dart';

class RingState {
  const RingState({
    this.scanning = false,
    this.busy = false,
    this.connected = false,
    this.results = const [],
    this.snapshot = const {},
    this.message = 'Ready to connect your ring',
    this.error,
  });
  final bool scanning, busy, connected;
  final List<ScanResult> results;
  final Map<String, dynamic> snapshot;
  final String message;
  final String? error;
  RingState copyWith({
    bool? scanning,
    bool? busy,
    bool? connected,
    List<ScanResult>? results,
    Map<String, dynamic>? snapshot,
    String? message,
    String? error,
  }) => RingState(
    scanning: scanning ?? this.scanning,
    busy: busy ?? this.busy,
    connected: connected ?? this.connected,
    results: results ?? this.results,
    snapshot: snapshot ?? this.snapshot,
    message: message ?? this.message,
    error: error,
  );
}

final ringProvider = NotifierProvider<RingController, RingState>(
  RingController.new,
);

class RingController extends Notifier<RingState> with WidgetsBindingObserver {
  static const channel = MethodChannel('telomy/wearable_sdk');
  StreamSubscription<List<ScanResult>>? _scan;
  StreamSubscription<bool>? _scanStatus;
  DateTime? _lastSaved;
  String? _activeId;
  int _generation = 0;
  @override
  RingState build() {
    ref.listen(authProvider, (previous, next) {
      if (previous?.asData?.value?.id != next.asData?.value?.id) {
        unawaited(disconnect());
      }
    });
    WidgetsBinding.instance.addObserver(this);
    channel.setMethodCallHandler((call) async {
      if (!ref.mounted) return;
      if (call.method == 'wearableDisconnected') {
        state = state.copyWith(
          connected: false,
          message: 'Ring disconnected. Tap Sync to reconnect.',
        );
        return;
      }
      if (call.method != 'wearableRealtime' ||
          _activeId == null ||
          call.arguments is! Map) {
        return;
      }
      final payload = Map<String, dynamic>.from(call.arguments as Map);
      state = state.copyWith(
        connected: true,
        snapshot: {...state.snapshot, ...payload},
        message: 'Receiving live ring data',
      );
      final now = DateTime.now();
      if (_lastSaved != null && now.difference(_lastSaved!).inSeconds < 30) {
        return;
      }
      final user = ref.read(authProvider).asData?.value;
      if (user == null) return;
      _lastSaved = now;
      try {
        await ref
            .read(wellnessProvider.notifier)
            .addMeasurements(
              liveRingMeasurements(
                payload,
                userId: user.id,
                deviceId: _activeId!,
                observedAt: now,
              ),
            );
      } catch (_) {
        if (ref.mounted) {
          state = state.copyWith(
            error:
                'Live data received but could not be saved. Please retry sync.',
          );
        }
      }
    });
    ref.onDispose(() {
      _generation++;
      WidgetsBinding.instance.removeObserver(this);
      _scan?.cancel();
      _scanStatus?.cancel();
      channel.setMethodCallHandler(null);
    });
    return const RingState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(disconnect());
  }

  static String name(ScanResult r) => r.advertisementData.advName.isNotEmpty
      ? r.advertisementData.advName
      : r.device.platformName.isNotEmpty
      ? r.device.platformName
      : 'Unnamed Bluetooth device';
  static bool likelyRing(ScanResult r) =>
      [
        'mini',
        'zone',
        'w596',
        'ring',
        'bonlala',
      ].any(name(r).toLowerCase().contains) ||
      r.advertisementData.serviceUuids.any(
        (u) =>
            u.toString().toLowerCase() ==
            '2b2eb000-1549-4c7e-bca9-0d498500d191',
      );
  Future<void> _permissions() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'The supplied Mini Zone SDK supports Android. An iOS vendor SDK is needed for ring sync.',
      );
    }
    final sdk = await channel.invokeMethod<int>('platformVersion') ?? 31;
    final permissions = sdk >= 31
        ? [Permission.bluetoothScan, Permission.bluetoothConnect]
        : [Permission.locationWhenInUse];
    final states = await permissions.request();
    if (states.values.any((s) => !s.isGranted)) {
      throw StateError(
        'Allow Nearby devices (or Location on older Android) in app settings, then retry.',
      );
    }
    if (!await FlutterBluePlus.isSupported) {
      throw StateError('Bluetooth LE is unavailable on this device.');
    }
    final adapter = await FlutterBluePlus.adapterState
        .where((s) => s != BluetoothAdapterState.unknown)
        .first
        .timeout(const Duration(seconds: 6));
    if (adapter != BluetoothAdapterState.on) {
      throw StateError('Turn on Bluetooth, then scan again.');
    }
  }

  Future<void> scan() async {
    if (state.busy || state.scanning) return;
    state = state.copyWith(
      scanning: true,
      results: [],
      message: 'Checking Bluetooth permissions…',
    );
    try {
      await _permissions();
      await FlutterBluePlus.setLogLevel(LogLevel.none, color: false);
      await _scan?.cancel();
      await _scanStatus?.cancel();
      _scan = FlutterBluePlus.scanResults.listen((values) {
        if (!ref.mounted) return;
        final sorted = [...values]
          ..sort((a, b) {
            final likely = (likelyRing(a) ? 0 : 1).compareTo(
              likelyRing(b) ? 0 : 1,
            );
            return likely == 0 ? b.rssi.compareTo(a.rssi) : likely;
          });
        state = state.copyWith(
          results: sorted,
          message: 'Select your ring from the nearby devices',
        );
      });
      _scanStatus = FlutterBluePlus.isScanning.listen((value) {
        if (ref.mounted) state = state.copyWith(scanning: value);
      });
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    } catch (e) {
      state = state.copyWith(
        scanning: false,
        error: e is StateError
            ? e.message.toString()
            : e is UnsupportedError
            ? e.message
            : 'Bluetooth scan failed. Check permissions and retry.',
      );
    }
  }

  Future<void> connect(ScanResult result) async {
    if (state.busy) return;
    await FlutterBluePlus.stopScan();
    await ref.read(wellnessProvider.notifier).saveRing({
      'id': result.device.remoteId.str,
      'name': name(result),
    });
    await sync();
  }

  Future<void> sync({int day = 0}) async {
    if (state.busy) return;
    final ring = ref.read(wellnessProvider).asData?.value.ring ?? {};
    final id = ring['id'] as String?;
    if (id == null) {
      state = state.copyWith(error: 'Add your ring first.');
      return;
    }
    final generation = ++_generation;
    state = state.copyWith(
      busy: true,
      message: 'Connecting and syncing. Keep your ring nearby…',
    );
    try {
      await _permissions();
      _activeId = id;
      final snapshot = await channel
          .invokeMapMethod<String, dynamic>('readSnapshot', {
            'mac': id,
            'name': ring['name'] ?? '',
            'day': day,
          })
          .timeout(const Duration(seconds: 95));
      if (!ref.mounted || generation != _generation) return;
      final data = snapshot ?? <String, dynamic>{};
      final now = DateTime.now();
      final synced = now.toIso8601String();
      final date = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: day)).toIso8601String().substring(0, 10);
      final reports = Map<String, dynamic>.from(ring['reports'] as Map? ?? {});
      reports[date] = data;
      await ref.read(wellnessProvider.notifier).saveRing({
        ...ring,
        'lastSync': synced,
        'report': data,
        'reports': reports,
        'dayOffset': day,
      });
      final user = ref.read(authProvider).asData?.value;
      if (user != null) {
        await ref
            .read(wellnessProvider.notifier)
            .addMeasurements(
              storedRingMeasurements(
                data,
                userId: user.id,
                deviceId: id,
                day: DateTime(
                  now.year,
                  now.month,
                  now.day,
                ).subtract(Duration(days: day)),
              ),
            );
      }
      state = state.copyWith(
        busy: false,
        connected: data['connected'] == true,
        snapshot: {...state.snapshot, ...data},
        message: data['recordError'] == null
            ? 'Sync finished. Available readings saved.'
            : 'Connected. Some history is unavailable; keep wearing the ring and retry.',
      );
    } catch (_) {
      if (!ref.mounted || generation != _generation) return;
      state = state.copyWith(
        busy: false,
        connected: false,
        error:
            'Could not sync. Charge the ring, close Mini Zone, check Bluetooth permissions, and retry.',
      );
      _activeId = null;
      try {
        await channel.invokeMethod<void>('disconnect');
      } catch (_) {}
    }
  }

  Future<void> disconnect() async {
    _generation++;
    _activeId = null;
    _lastSaved = null;
    try {
      if (Platform.isAndroid) {
        await FlutterBluePlus.stopScan();
        await channel.invokeMethod<void>('disconnect');
      }
    } catch (_) {}
    if (ref.mounted) {
      state = const RingState(
        message: 'Disconnected. Your saved readings are still available.',
      );
    }
  }

  Future<void> forget() async {
    await disconnect();
    await ref.read(wellnessProvider.notifier).saveRing({});
  }
}
