import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/supabase_config.dart';
import '../../auth/providers/auth_provider.dart';
import '../../settings/services/notification_service.dart';
import '../data/life_event_service.dart';
import '../models/event_check_in.dart';
import '../models/life_event.dart';
import 'life_event_state.dart';

/// Realtime can drop a message. A slow poll alongside it means a check-in never
/// goes missing in front of someone — the same belt-and-braces the activity
/// report screen uses.
const _pollInterval = Duration(seconds: 10);

/// Redraws the elapsed-time label while an event runs.
const _tickInterval = Duration(seconds: 30);

final lifeEventServiceProvider = Provider<LifeEventService>(
  (ref) => LifeEventService(Supabase.instance.client),
);

final lifeEventNotificationsProvider = Provider<NotificationService>(
  (ref) => NotificationService(),
);

final lifeEventProvider =
    NotifierProvider<LifeEventController, LifeEventState>(
      LifeEventController.new,
    );

class LifeEventController extends Notifier<LifeEventState> {
  RealtimeChannel? _channel;
  Timer? _poll;
  Timer? _tick;
  String? _userId;

  @override
  LifeEventState build() {
    ref.onDispose(_teardown);
    final user = ref.watch(authProvider).asData?.value;
    _userId = user?.id;
    if (user != null && SupabaseConfig.configured) {
      _subscribe(user.id);
      // Fire and forget: an open event from a previous session should reappear,
      // but nothing on this screen should block on the network.
      unawaited(_restore(user.id));
    }
    return const LifeEventState();
  }

  LifeEventService get _service => ref.read(lifeEventServiceProvider);

  void _teardown() {
    _poll?.cancel();
    _tick?.cancel();
    final channel = _channel;
    _channel = null;
    if (channel != null) Supabase.instance.client.removeChannel(channel);
  }

  void _subscribe(String userId) {
    final client = Supabase.instance.client;
    _channel = client
        .channel('life_event_predictions_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'predictions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) => _consume(payload.newRecord),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'predictions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) => _consume(payload.newRecord),
        )
        .subscribe();
  }

  /// Rejoins an event that is still open — the backend timer kept running while
  /// the app was closed, so its check-ins are already in the database.
  Future<void> _restore(String userId) async {
    try {
      final open = await _service.openEvent(userId);
      if (open == null) return;
      state = state.startedWith(open);
      await _refresh(open.id, notify: false);
      _startTimers();
    } catch (_) {
      // Nothing to show is the correct outcome of a failed restore.
    }
  }

  void _consume(Map<String, dynamic> row) {
    final incoming = EventCheckIn.fromRow(row);
    if (incoming == null) return;
    final before = state;
    final after = before.receive(incoming);
    if (identical(after, before)) return;
    state = after;
    if (after.checkIns.length > before.checkIns.length) {
      _notify(after.checkIns.first);
    }
  }

  void _notify(EventCheckIn checkIn) {
    // The phone is often in a pocket when this matters, so the notification is
    // the real delivery and the card is the record.
    unawaited(
      ref
          .read(lifeEventNotificationsProvider)
          .showNow(
            id: checkIn.reason.hashCode & 0x7fffffff,
            title: checkIn.needsEscalation
                ? 'Worth checking now'
                : 'While you’re still going',
            body: checkIn.summary,
          )
          .catchError((_) {
            // A blocked notification permission must never break the screen.
          }),
    );
  }

  void _startTimers() {
    _poll?.cancel();
    _tick?.cancel();
    _poll = Timer.periodic(_pollInterval, (_) {
      final event = state.event;
      if (event != null && state.isRunning) _refresh(event.id);
    });
    // Rebuilds the card so "running 23 min" stays honest.
    _tick = Timer.periodic(_tickInterval, (_) {
      if (state.isRunning) state = state.copyWith();
    });
  }

  Future<void> _refresh(String eventId, {bool notify = true}) async {
    try {
      final rows = await _service.predictionsFor(eventId);
      for (final row in rows) {
        if (notify) {
          _consume(row);
        } else {
          final incoming = EventCheckIn.fromRow(row);
          if (incoming != null) state = state.receive(incoming);
        }
      }
    } catch (_) {
      // A failed poll is covered by the next tick and by Realtime.
    }
  }

  Future<void> start(LifeEventType type) async {
    final userId = _userId;
    if (userId == null || state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final event = await _service.start(userId: userId, eventType: type.key);
      if (event == null) {
        state = state.copyWith(
          busy: false,
          error: 'Could not start that. Please try again.',
        );
        return;
      }
      state = state.startedWith(event);
      _startTimers();
    } catch (_) {
      state = state.copyWith(
        busy: false,
        error: 'Could not start that. Check your connection and try again.',
      );
    }
  }

  Future<void> stop() async {
    final userId = _userId;
    final event = state.event;
    if (userId == null || event == null || state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final ended = await _service.stop(userId: userId, eventId: event.id);
      _poll?.cancel();
      _tick?.cancel();
      state = state.copyWith(event: ended ?? event, busy: false);
      // The closing analysis takes a few seconds; keep looking for it.
      _poll = Timer.periodic(_pollInterval, (timer) {
        if (state.analysis != null) {
          timer.cancel();
          return;
        }
        _refresh(event.id);
      });
    } catch (_) {
      state = state.copyWith(
        busy: false,
        error: 'Could not stop that. Check your connection and try again.',
      );
    }
  }
}
