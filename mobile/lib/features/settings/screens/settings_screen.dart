import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/widgets/async_action.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../devices/providers/ring_provider.dart';
import '../providers/theme_provider.dart';
import 'package:go_router/go_router.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(wellnessProvider).asData?.value;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Settings & privacy',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 24),
        DropdownButtonFormField<ThemeMode>(
          initialValue: ref.watch(themeProvider),
          decoration: const InputDecoration(labelText: 'Appearance'),
          items: ThemeMode.values
              .map((m) => DropdownMenuItem(value: m, child: Text(m.name)))
              .toList(),
          onChanged: (v) {
            if (v != null) ref.read(themeProvider.notifier).setMode(v);
          },
        ),
        const SizedBox(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Preview sample health data'),
          subtitle: const Text(
            'Preview is separate from personal records and never included in your reports.',
          ),
          value: data?.demo ?? false,
          onChanged: data == null
              ? null
              : (v) => runAction(
                  context,
                  () => ref.read(wellnessProvider.notifier).setDemo(v),
                ),
        ),
        const Divider(),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.admin_panel_settings_outlined),
          title: const Text('Health data consent & sources'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/health-consent'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.notifications_active_outlined),
          title: const Text('Notifications & privacy controls'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/notifications-privacy'),
        ),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.lock_outline),
          title: Text('Data collection'),
          subtitle: Text(
            'Profile and manual records are entered by you. Ring readings are collected only after you connect. Records are saved in encrypted platform storage on this device. Cloud health sync is not enabled.',
          ),
        ),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.bluetooth),
          title: Text('Ring access'),
          subtitle: Text(
            'Bluetooth permissions are requested on Scan. Ring connections stop when the app goes into the background. No continuous location tracking.',
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: data == null
              ? null
              : () async {
                  final yes = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Delete personal data on this device?'),
                      content: const Text(
                        'This removes your profile, measurements, journal and saved ring. It does not delete a server account. This cannot be undone.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('Delete data'),
                        ),
                      ],
                    ),
                  );
                  if (yes == true && context.mounted) {
                    await runAction(context, () async {
                      await ref.read(ringProvider.notifier).disconnect();
                      await ref
                          .read(wellnessProvider.notifier)
                          .clearPersonalData();
                    }, success: 'Local personal data deleted');
                  }
                },
          child: const Text('Delete local personal data'),
        ),
      ],
    );
  }
}
