import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/widgets/async_action.dart';
import '../../auth/providers/auth_provider.dart';
import '../../devices/providers/ring_provider.dart';
import '../../journal/providers/wellness_provider.dart';
import '../models/reminder_settings.dart';
import '../providers/notification_provider.dart';
import '../services/data_export_service.dart';

class NotificationsPrivacyScreen extends ConsumerWidget {
  const NotificationsPrivacyScreen({super.key});

  String _time(BuildContext context, int minute) =>
      TimeOfDay(hour: minute ~/ 60, minute: minute % 60).format(context);

  Future<int?> _pickTime(BuildContext context, int minute) async {
    final value = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
    );
    return value == null ? null : value.hour * 60 + value.minute;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(wellnessProvider).asData?.value;
    final settings = ref.watch(reminderSettingsProvider);
    final controller = ref.read(notificationSettingsControllerProvider);
    Future<void> save(ReminderSettings value) =>
        runAction(context, () => controller.save(value));
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Notifications & privacy',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 20),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Wellness notifications'),
          subtitle: const Text('Only reminders you configure are scheduled.'),
          value: settings.enabled,
          onChanged: data == null
              ? null
              : (enabled) async {
                  if (enabled) {
                    await runAction(context, () async {
                      final granted = await controller.enable(settings);
                      if (!granted) {
                        throw StateError(
                          'Notification access was not granted in system settings.',
                        );
                      }
                    });
                  } else {
                    await save(settings.copyWith(enabled: false));
                  }
                },
        ),
        const Divider(),
        _ReminderTile(
          title: 'Hydration',
          value: settings.water,
          time: _time(context, settings.waterMinute),
          enabled: settings.enabled,
          onToggle: (v) => save(settings.copyWith(water: v)),
          onTime: () async {
            final value = await _pickTime(context, settings.waterMinute);
            if (value != null) {
              await save(settings.copyWith(waterMinute: value));
            }
          },
        ),
        _ReminderTile(
          title: 'Movement',
          value: settings.movement,
          time: _time(context, settings.movementMinute),
          enabled: settings.enabled,
          onToggle: (v) => save(settings.copyWith(movement: v)),
          onTime: () async {
            final value = await _pickTime(context, settings.movementMinute);
            if (value != null) {
              await save(settings.copyWith(movementMinute: value));
            }
          },
        ),
        _ReminderTile(
          title: 'Sleep wind-down',
          value: settings.sleep,
          time: _time(context, settings.sleepMinute),
          enabled: settings.enabled,
          onToggle: (v) => save(settings.copyWith(sleep: v)),
          onTime: () async {
            final value = await _pickTime(context, settings.sleepMinute);
            if (value != null) {
              await save(settings.copyWith(sleepMinute: value));
            }
          },
        ),
        _ReminderTile(
          title: 'Daily review',
          value: settings.dailyReview,
          time: _time(context, settings.reviewMinute),
          enabled: settings.enabled,
          onToggle: (v) => save(settings.copyWith(dailyReview: v)),
          onTime: () async {
            final value = await _pickTime(context, settings.reviewMinute);
            if (value != null) {
              await save(settings.copyWith(reviewMinute: value));
            }
          },
        ),
        const SizedBox(height: 20),
        Text('Trend alerts', style: Theme.of(context).textTheme.titleLarge),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Conservative health trend alerts'),
          subtitle: const Text(
            'Alerts describe changes in your data and do not diagnose a condition.',
          ),
          value: settings.trendAlerts,
          onChanged: data == null
              ? null
              : (v) => save(settings.copyWith(trendAlerts: v)),
        ),
        _ThresholdField(
          label: 'Resting heart-rate change (%)',
          value: settings.restingHeartRateChange,
          onSaved: (v) => save(settings.copyWith(restingHeartRateChange: v)),
        ),
        const SizedBox(height: 12),
        _ThresholdField(
          label: 'Low sleep threshold (hours)',
          value: settings.minimumSleepHours,
          onSaved: (v) => save(settings.copyWith(minimumSleepHours: v)),
        ),
        const SizedBox(height: 28),
        Text('Your data', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.download_outlined),
          title: const Text('Export my data'),
          subtitle: const Text(
            'Copies a structured JSON export to the clipboard.',
          ),
          onTap: data == null
              ? null
              : () => runAction(context, () async {
                  final export = const JsonDataExportService().createExport(
                    data,
                  );
                  await Clipboard.setData(ClipboardData(text: export));
                }, success: 'Personal data export copied'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.delete_forever_outlined),
          title: const Text('Delete account'),
          subtitle: const Text(
            'Deletes the account and locally stored health data.',
          ),
          onTap: data == null ? null : () => _deleteAccount(context, ref),
        ),
      ],
    );
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
          'Your account and personal health data will be permanently deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await runAction(context, () async {
      await ref
          .read(notificationServiceProvider)
          .apply(const ReminderSettings());
      await ref.read(ringProvider.notifier).disconnect();
      await ref.read(wellnessProvider.notifier).clearPersonalData();
      await ref.read(authProvider.notifier).deleteAccount();
    });
  }
}

class _ReminderTile extends StatelessWidget {
  const _ReminderTile({
    required this.title,
    required this.value,
    required this.time,
    required this.enabled,
    required this.onToggle,
    required this.onTime,
  });
  final String title;
  final bool value;
  final String time;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTime;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    leading: Switch(value: value, onChanged: enabled ? onToggle : null),
    trailing: TextButton(
      onPressed: enabled && value ? onTime : null,
      child: Text(time),
    ),
  );
}

class _ThresholdField extends StatefulWidget {
  const _ThresholdField({
    required this.label,
    required this.value,
    required this.onSaved,
  });
  final String label;
  final double value;
  final ValueChanged<double> onSaved;
  @override
  State<_ThresholdField> createState() => _ThresholdFieldState();
}

class _ThresholdFieldState extends State<_ThresholdField> {
  late final TextEditingController controller = TextEditingController(
    text: widget.value.toStringAsFixed(widget.value % 1 == 0 ? 0 : 1),
  );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(
      labelText: widget.label,
      suffixIcon: IconButton(
        icon: const Icon(Icons.check),
        onPressed: () {
          final value = double.tryParse(controller.text);
          if (value != null && value > 0) widget.onSaved(value);
        },
      ),
    ),
    onSubmitted: (text) {
      final value = double.tryParse(text);
      if (value != null && value > 0) widget.onSaved(value);
    },
  );
}
