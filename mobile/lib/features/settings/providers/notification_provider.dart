import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../journal/providers/wellness_provider.dart';
import '../models/reminder_settings.dart';
import '../services/notification_service.dart';

final notificationServiceProvider = Provider((_) => NotificationService());

final reminderSettingsProvider = Provider<ReminderSettings>((ref) {
  final profile = ref.watch(wellnessProvider).asData?.value.profile ?? const {};
  return ReminderSettings.fromProfile(profile);
});

final notificationSettingsControllerProvider = Provider(
  (ref) => NotificationSettingsController(ref),
);

class NotificationSettingsController {
  const NotificationSettingsController(this.ref);
  final Ref ref;

  Future<bool> enable(ReminderSettings settings) async {
    final service = ref.read(notificationServiceProvider);
    final granted = await service.requestPermission();
    final next = settings.copyWith(enabled: granted);
    await save(next);
    return granted;
  }

  Future<void> save(ReminderSettings settings) async {
    final current = await ref.read(wellnessProvider.future);
    await ref
        .read(wellnessProvider.notifier)
        .saveProfile(settings.applyTo(current.profile));
    await ref.read(notificationServiceProvider).apply(settings);
  }
}
