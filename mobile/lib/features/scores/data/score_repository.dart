import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/supabase_config.dart';
import '../models/score_snapshot.dart';

/// Reads server-computed scores.
///
/// The app's primary read is the `score_snapshots` table, not the REST
/// endpoint: it rides the Supabase client the app already uses, needs no token
/// plumbing on the critical path, and keeps the agent invisible to the
/// frontend. REST is for "recompute now, I just confirmed new data".
class ScoreRepository {
  ScoreRepository([SupabaseClient? client]) : _client = client;

  final SupabaseClient? _client;

  SupabaseClient? get _db {
    if (!SupabaseConfig.configured) return null;
    return _client ?? Supabase.instance.client;
  }

  /// The snapshot for a given day, or null when the server has not computed it.
  ///
  /// Null is a real answer — "not computed yet" — and the caller must not turn
  /// it into a zero.
  Future<ScoreSnapshot?> snapshotFor({
    required String userId,
    required String kind,
    required DateTime day,
  }) async {
    final db = _db;
    if (db == null) return null;
    final asOf = DateTime.utc(day.year, day.month, day.day)
        .toIso8601String()
        .split('T')
        .first;
    try {
      final rows = await db
          .from('score_snapshots')
          .select()
          .eq('user_id', userId)
          .eq('score_kind', kind)
          .eq('as_of_date', asOf)
          .limit(1);
      if (rows.isEmpty) return null;
      return ScoreSnapshot.fromRow(Map<String, dynamic>.from(rows.first), kind: kind);
    } catch (_) {
      // Offline, or the table is not reachable. The caller falls back to the
      // local estimate, which is exactly what it is for.
      return null;
    }
  }

  /// The most recent snapshot of a kind, whatever day it belongs to.
  ///
  /// Separate from [snapshotFor] because not every score is about a day.
  /// Readiness is, and showing Tuesday's on Thursday would be wrong -- which is
  /// why that method pins the date. A biological age is about a blood draw, so
  /// there is no "today's" one to ask for: pinning the date would return
  /// nothing on every day except the one the sample was taken.
  Future<ScoreSnapshot?> latestSnapshot({
    required String userId,
    required String kind,
  }) async {
    final db = _db;
    if (db == null) return null;
    try {
      final rows = await db
          .from('score_snapshots')
          .select()
          .eq('user_id', userId)
          .eq('score_kind', kind)
          .order('as_of_date', ascending: false)
          .limit(1);
      if (rows.isEmpty) return null;
      return ScoreSnapshot.fromRow(
        Map<String, dynamic>.from(rows.first),
        kind: kind,
      );
    } catch (_) {
      return null;
    }
  }
}
