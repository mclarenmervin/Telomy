import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/widgets/async_action.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../health/providers/platform_health_provider.dart';
import 'dart:io';

class HealthConsentScreen extends ConsumerWidget {
  const HealthConsentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(wellnessProvider).asData?.value;
    final profile = data?.profile ?? const <String, String>{};
    final health = ref.watch(platformHealthProvider);
    final platformKey = Platform.isIOS
        ? 'consentAppleHealth'
        : 'consentHealthConnect';
    final platformName = Platform.isIOS ? 'Apple Health' : 'Health Connect';
    Future<void> setConsent(String key, bool enabled) async {
      await runAction(
        context,
        () => ref.read(wellnessProvider.notifier).saveProfile({
          ...profile,
          key: enabled.toString(),
        }),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Health data consent',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 12),
        const Text(
          'Choose which sources Telomy may read. Turning access off stops future collection; you can delete stored records separately.',
        ),
        const SizedBox(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Manual health records'),
          subtitle: const Text(
            'Profile, measurements, meals, workouts and check-ins you enter.',
          ),
          value: profile['consentManual'] == 'true',
          onChanged: data == null
              ? null
              : (value) => setConsent('consentManual', value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Connected ring data'),
          subtitle: const Text(
            'Readings are collected after you connect and sync your ring.',
          ),
          value: profile['consentWearable'] == 'true',
          onChanged: data == null
              ? null
              : (value) => setConsent('consentWearable', value),
        ),
        const Divider(),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.health_and_safety_outlined),
          title: Text(platformName),
          subtitle: Text(
            profile[platformKey] == 'true'
                ? 'Connected${profile['${platformKey}LastSync'] == null ? '' : ' · synced ${profile['${platformKey}LastSync']!.substring(0, 10)}'}'
                : 'Import supported records from the last 30 days',
          ),
        ),
        if (health.busy) const LinearProgressIndicator(),
        if (health.message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(health.message!),
          ),
        if (health.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              health.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (Platform.isIOS || Platform.isAndroid)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: health.busy
                    ? null
                    : profile[platformKey] == 'true'
                    ? () => ref.read(platformHealthProvider.notifier).sync()
                    : () => ref
                          .read(platformHealthProvider.notifier)
                          .connectAndSync(),
                child: Text(
                  profile[platformKey] == 'true'
                      ? 'Sync now'
                      : 'Connect $platformName',
                ),
              ),
              if (profile[platformKey] == 'true')
                OutlinedButton(
                  onPressed: health.busy
                      ? null
                      : () => ref
                            .read(platformHealthProvider.notifier)
                            .disconnect(),
                  child: const Text('Revoke access'),
                ),
            ],
          ),
      ],
    );
  }
}
