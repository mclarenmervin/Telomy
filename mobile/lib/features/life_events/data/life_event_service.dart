import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/life_event.dart';

/// Reads and writes the backend `events` table.
///
/// This table is the platform's single trigger contract: a row here is what
/// starts the agent. The app never calls the agent — it only writes the row and
/// listens for what comes back in `predictions`.
class LifeEventService {
  LifeEventService(this._client);

  final SupabaseClient _client;

  /// Opens an event. `source: 'manual'` marks it as a button press rather than
  /// a voice command or a detector guess.
  Future<LifeEvent?> start({
    required String userId,
    required String eventType,
  }) async {
    final rows = await _client
        .from('events')
        .insert({
          'user_id': userId,
          'event_type': eventType,
          'status': 'started',
          'source': 'manual',
        })
        .select()
        .limit(1);
    if (rows.isEmpty) return null;
    return LifeEvent.fromRow(Map<String, dynamic>.from(rows.first));
  }

  /// Closes an event, which also stops the backend's check-in timer.
  Future<LifeEvent?> stop({
    required String userId,
    required String eventId,
  }) async {
    final rows = await _client
        .from('events')
        .update({
          'status': 'ended',
          'ended_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', eventId)
        .eq('user_id', userId)
        .select()
        .limit(1);
    if (rows.isEmpty) return null;
    return LifeEvent.fromRow(Map<String, dynamic>.from(rows.first));
  }

  /// The user's still-open event, if any.
  ///
  /// Reopened on launch so an event survives the app being closed — the backend
  /// timer keeps running regardless, so the screen must be able to rejoin it.
  Future<LifeEvent?> openEvent(String userId) async {
    final rows = await _client
        .from('events')
        .select()
        .eq('user_id', userId)
        .eq('status', 'started')
        .order('started_at', ascending: false)
        .limit(1);
    if (rows.isEmpty) return null;
    return LifeEvent.fromRow(Map<String, dynamic>.from(rows.first));
  }

  /// Predictions already written for an event, so reopening the app shows the
  /// check-ins that arrived while it was closed.
  Future<List<Map<String, dynamic>>> predictionsFor(String eventId) async {
    final rows = await _client
        .from('predictions')
        .select()
        .eq('event_id', eventId)
        .order('created_at');
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
}
