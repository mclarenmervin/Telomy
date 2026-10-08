import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/supabase_config.dart';
import '../models/epigenetic_clock.dart';

/// Reads and records third-party epigenetic clock results.
///
/// Reads go straight to the table, like every other mobile read: it rides the
/// Supabase client the app already holds and keeps the agent invisible to the
/// frontend.
///
/// Writes are the unusual part. The app inserts these rows directly, which it
/// does for almost nothing else -- lab values go through extraction and a
/// confirmation endpoint, and scores are written only under the service role.
/// The difference is that there is no server-side workflow to protect: an
/// epigenetic result is a number the user copies off a report from another
/// laboratory, with no status, no extraction and nothing to verify it against.
/// RLS scopes it to their own rows and the table's check constraint pins
/// `source` to `third_party`, so the app cannot record one of these as ours.
class EpigeneticRepository {
  EpigeneticRepository([SupabaseClient? client]) : _client = client;

  final SupabaseClient? _client;

  SupabaseClient? get _db {
    if (!SupabaseConfig.configured) return null;
    return _client ?? Supabase.instance.client;
  }

  /// The user's clocks, newest first. Empty when there are none *and* when we
  /// could not look -- the caller shows the same "add one" state either way,
  /// which is the one place those two really are the same.
  Future<List<EpigeneticClock>> forUser(String userId) async {
    final db = _db;
    if (db == null) return const [];
    try {
      final rows = await db
          .from('epigenetic_results')
          .select('clock,value,unit,provider,collected_at,source')
          .eq('user_id', userId)
          .order('collected_at', ascending: false);
      return parseClocks(
        [for (final row in rows) Map<String, dynamic>.from(row)],
      );
    } catch (_) {
      return const [];
    }
  }

  /// Records a result the user has from a provider.
  ///
  /// `source` is not a parameter. It is pinned here and again by the table's
  /// check constraint, because the one thing that must never happen is our name
  /// against a number somebody else measured.
  Future<void> record({
    required String userId,
    required String clock,
    required double value,
    required String unit,
    required String provider,
    required DateTime collectedAt,
  }) async {
    final db = _db;
    if (db == null) return;
    if (!knownClocks.contains(clock)) {
      throw ArgumentError.value(clock, 'clock', 'not a clock we display');
    }
    await db.from('epigenetic_results').insert({
      'user_id': userId,
      'clock': clock,
      'value': value,
      'unit': unit,
      'provider': provider,
      'collected_at': collectedAt.toUtc().toIso8601String(),
      'source': 'third_party',
    });
  }
}
