import '../../settings/services/notification_service.dart';

/// Asks for notification permission the first time the user starts an event.
///
/// Starting an event is the honest moment to ask: the user has just said "watch
/// this", and a check-in is useless if the phone cannot speak. Asking at launch
/// instead would be a dialog with no context behind it.
///
/// Asked at most once per app run — the OS shows its own dialog only once, and
/// re-asking would add a pointless await between the tap and the event being
/// created.
class CheckInPermission {
  CheckInPermission(this._notifications);

  final NotificationService _notifications;

  bool _asked = false;
  bool _granted = false;

  /// Whether the last answer was yes. False before [ensure] has run, and false
  /// on a platform that cannot answer.
  bool get granted => _granted;

  Future<void> ensure() async {
    if (_asked) return;
    _asked = true;
    try {
      _granted = await _notifications.requestPermission();
    } catch (_) {
      // A platform without a notifications plugin, or a user who dismissed the
      // dialog, must never stop the event being logged. The in-app card is
      // still a complete record of what the agent said.
      _granted = false;
    }
  }
}
