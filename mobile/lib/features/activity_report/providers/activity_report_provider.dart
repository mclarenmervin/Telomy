import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/supabase_config.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/activity_report.dart';

/// How long to keep waiting for a report before telling the user plainly.
const reportTimeout = Duration(seconds: 90);

/// Realtime can drop a message; a slow poll alongside it means a demo never
/// hangs on an invisible failure.
const _pollInterval = Duration(seconds: 4);

class ActivityReportState {
  const ActivityReportState({
    this.awaitingSessionId,
    this.report,
    this.timedOut = false,
  });

  /// Set while a finished session has been saved but no report has arrived yet.
  final String? awaitingSessionId;
  final ActivityReport? report;
  final bool timedOut;

  bool get waiting => awaitingSessionId != null && report == null && !timedOut;

  ActivityReportState copyWith({
    String? awaitingSessionId,
    ActivityReport? report,
    bool? timedOut,
    bool clearAwaiting = false,
    bool clearReport = false,
  }) => ActivityReportState(
    awaitingSessionId: clearAwaiting ? null : (awaitingSessionId ?? this.awaitingSessionId),
    report: clearReport ? null : (report ?? this.report),
    timedOut: timedOut ?? this.timedOut,
  );
}

final activityReportProvider =
    NotifierProvider<ActivityReportController, ActivityReportState>(
      ActivityReportController.new,
    );

class ActivityReportController extends Notifier<ActivityReportState> {
  RealtimeChannel? _channel;
  Timer? _poll;
  Timer? _timeout;

  @override
  ActivityReportState build() {
    ref.onDispose(_teardown);
    final user = ref.watch(authProvider).asData?.value;
    if (user != null && SupabaseConfig.configured) {
      _subscribe(user.id);
    }
    return const ActivityReportState();
  }

  void _teardown() {
    _poll?.cancel();
    _timeout?.cancel();
    final channel = _channel;
    _channel = null;
    if (channel != null) Supabase.instance.client.removeChannel(channel);
  }

  void _subscribe(String userId) {
    final client = Supabase.instance.client;
    _channel = client
        .channel('activity_reports_$userId')
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

  void _consume(Map<String, dynamic> row) {
    final report = ActivityReport.fromRow(row);
    if (report == null) return;
    final awaiting = state.awaitingSessionId;
    // Ignore reports for other sessions while waiting on a specific one.
    if (awaiting != null && report.sessionId != awaiting) return;
    _poll?.cancel();
    _timeout?.cancel();
    state = ActivityReportState(report: report);
  }

  /// Called once a finished session has been saved. The user is free to leave
  /// this screen; nothing blocks on the result.
  void awaitReportFor(String sessionId) {
    _poll?.cancel();
    _timeout?.cancel();
    state = ActivityReportState(awaitingSessionId: sessionId);

    _poll = Timer.periodic(_pollInterval, (_) => _fetch(sessionId));
    _timeout = Timer(reportTimeout, () {
      _poll?.cancel();
      if (state.report == null) {
        state = state.copyWith(timedOut: true);
      }
    });
  }

  Future<void> _fetch(String sessionId) async {
    if (!SupabaseConfig.configured) return;
    try {
      final rows = await Supabase.instance.client
          .from('predictions')
          .select()
          .eq('event_id', sessionId)
          .eq('kind', 'activity_summary')
          .limit(1);
      if (rows.isNotEmpty) _consume(Map<String, dynamic>.from(rows.first));
    } catch (_) {
      // A failed poll is not worth surfacing; the timeout covers the user.
    }
  }

  /// Loads the most recent report so the screen is not empty on first open.
  Future<void> loadLatest() async {
    if (!SupabaseConfig.configured) return;
    final user = ref.read(authProvider).asData?.value;
    if (user == null) return;
    try {
      final rows = await Supabase.instance.client
          .from('predictions')
          .select()
          .eq('user_id', user.id)
          .eq('kind', 'activity_summary')
          .order('created_at', ascending: false)
          .limit(1);
      if (rows.isNotEmpty && state.report == null && !state.waiting) {
        final report = ActivityReport.fromRow(Map<String, dynamic>.from(rows.first));
        if (report != null) state = ActivityReportState(report: report);
      }
    } catch (_) {
      // Nothing to show is an acceptable outcome here.
    }
  }

  void dismiss() {
    _poll?.cancel();
    _timeout?.cancel();
    state = const ActivityReportState();
  }
}
