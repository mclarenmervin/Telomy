import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import '../models/reminder_settings.dart';

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_telomy'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    tz_data.initializeTimeZones();
    try {
      final local = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(local.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.UTC);
    }
    _initialized = true;
  }

  Future<bool> requestPermission() async {
    await initialize();
    if (Platform.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          true;
    }
    if (Platform.isIOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    return false;
  }

  Future<void> apply(ReminderSettings settings) async {
    await initialize();
    await _plugin.cancelAllPendingNotifications();
    if (!settings.enabled) return;
    if (settings.water) {
      await _daily(
        1001,
        settings.waterMinute,
        'Hydration check-in',
        'A glass of water may help you stay on track.',
      );
    }
    if (settings.movement) {
      await _daily(
        1002,
        settings.movementMinute,
        'Movement check-in',
        'A short walk or stretch can add useful activity to your day.',
      );
    }
    if (settings.sleep) {
      await _daily(
        1003,
        settings.sleepMinute,
        'Prepare for sleep',
        'Start winding down when it fits your evening.',
      );
    }
    if (settings.dailyReview) {
      await _daily(
        1004,
        settings.reviewMinute,
        'Daily health review',
        'Review today’s data and complete any missing check-ins.',
      );
    }
  }

  Future<void> _daily(int id, int minute, String title, String body) async {
    final now = tz.TZDateTime.now(tz.local);
    var date = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      minute ~/ 60,
      minute % 60,
    );
    if (!date.isAfter(now)) date = date.add(const Duration(days: 1));
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: date,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'daily_wellness',
          'Daily wellness reminders',
          channelDescription: 'Reminders configured in Telomy settings',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }
}
