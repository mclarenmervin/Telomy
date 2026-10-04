import 'package:flutter/foundation.dart';

import '../models/event_check_in.dart';
import '../models/life_event.dart';

/// Everything the event card renders, and the rules for folding a new
/// prediction into it.
///
/// Kept free of Riverpod and Supabase so the merge rules — which is where the
/// duplicate-notification bugs live — can be tested as plain functions.
@immutable
class LifeEventState {
  const LifeEventState({
    this.event,
    this.checkIns = const [],
    this.acknowledged = false,
    this.analysis,
    this.busy = false,
    this.error,
  });

  final LifeEvent? event;

  /// Newest first: the most recent thing the agent noticed sits at the top.
  final List<EventCheckIn> checkIns;

  /// The agent confirmed it is tracking. Worth showing, because the gap between
  /// tapping start and the first check-in is otherwise silent.
  final bool acknowledged;

  /// The end-of-event report, once the user has stopped.
  final EventCheckIn? analysis;

  /// A start or stop call is in flight.
  final bool busy;
  final String? error;

  bool get isRunning => event?.isOpen ?? false;

  LifeEventState copyWith({
    LifeEvent? event,
    List<EventCheckIn>? checkIns,
    bool? acknowledged,
    EventCheckIn? analysis,
    bool? busy,
    String? error,
    bool clearError = false,
  }) => LifeEventState(
    event: event ?? this.event,
    checkIns: checkIns ?? this.checkIns,
    acknowledged: acknowledged ?? this.acknowledged,
    analysis: analysis ?? this.analysis,
    busy: busy ?? this.busy,
    error: clearError ? null : (error ?? this.error),
  );

  /// A fresh event wipes the previous one's conversation: leaving yesterday's
  /// check-ins on screen under today's event would misattribute them.
  LifeEventState startedWith(LifeEvent started) => LifeEventState(event: started);

  /// Folds one prediction row into the state. Ignores anything that is not
  /// about the event currently on screen.
  LifeEventState receive(EventCheckIn incoming) {
    final current = event;
    if (current == null || incoming.eventId != current.id) return this;

    switch (incoming.kind) {
      case EventPredictionKind.ack:
        return copyWith(acknowledged: true);
      case EventPredictionKind.analysis:
        return copyWith(analysis: incoming);
      case EventPredictionKind.checkIn:
        // The backend delivers each reason at most once, but Realtime can
        // deliver the same row twice (an INSERT and a later UPDATE), so the
        // reason is the identity here too.
        if (checkIns.any((c) => c.reason == incoming.reason)) return this;
        final merged = [...checkIns, incoming]
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return copyWith(checkIns: merged);
    }
  }
}
