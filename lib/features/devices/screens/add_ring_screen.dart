import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../core/widgets/async_action.dart';
import '../providers/ring_provider.dart';
import '../../journal/providers/wellness_provider.dart';

class AddRingScreen extends ConsumerWidget {
  const AddRingScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ring = ref.watch(ringProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Add ring')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Icon(
              Icons.trip_origin,
              size: 90,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              'Meet your daily companion.',
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 16),
            const Text(
              'Charge your Mini Zone ring, keep it next to your phone, and close Mini Zone or Immortiva so they release the Bluetooth connection.',
            ),
            const SizedBox(height: 16),
            const Text(
              'Telomy asks for Bluetooth access when you scan. On Android 11 and earlier, scanning also requires Location permission. Your location is not recorded.',
            ),
            if (!Platform.isAndroid)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text(
                  'The supplied vendor SDK is Android-only. Ring sync on iOS requires the matching vendor SDK. Manual tracking works on iOS.',
                ),
              ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: ring.scanning || ring.busy || !Platform.isAndroid
                  ? null
                  : () => ref.read(ringProvider.notifier).scan(),
              icon: const Icon(Icons.bluetooth_searching),
              label: Text(ring.scanning ? 'Scanning…' : 'Scan for my ring'),
            ),
            TextButton(
              onPressed: openAppSettings,
              child: const Text('Open permission settings'),
            ),
            if (ring.scanning || ring.busy) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(ring.message),
            if (ring.error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  ring.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (!ring.scanning && ring.results.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'No devices listed yet. Scan with the ring awake and nearby.',
                ),
              ),
            for (final result in ring.results)
              Card(
                child: ListTile(
                  leading: Icon(
                    RingController.likelyRing(result)
                        ? Icons.trip_origin
                        : Icons.bluetooth,
                  ),
                  title: Text(RingController.name(result)),
                  subtitle: Text(
                    '${RingController.likelyRing(result) ? 'Possible Mini Zone ring' : 'Compatibility not confirmed'} · ${result.rssi} dBm',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: ring.busy
                      ? null
                      : () async {
                          final yes = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                              title: const Text('Connect this device?'),
                              content: Text(
                                'Connect to ${RingController.name(result)}? Bluetooth name matching alone does not prove compatibility.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(c, false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(c, true),
                                  child: const Text('Connect'),
                                ),
                              ],
                            ),
                          );
                          if (yes != true || !context.mounted) return;
                          final ok = await runAction(context, () async {
                            final current = ref
                                .read(wellnessProvider)
                                .asData!
                                .value;
                            await ref
                                .read(wellnessProvider.notifier)
                                .saveProfile({
                                  ...current.profile,
                                  'consentWearable': 'true',
                                });
                            await ref
                                .read(ringProvider.notifier)
                                .connect(result);
                          });
                          if (ok &&
                              context.mounted &&
                              ref.read(ringProvider).connected) {
                            Navigator.pop(context);
                          }
                        },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
