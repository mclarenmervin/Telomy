import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/supabase_config.dart';
import '../models/clinical_insight.dart';

/// Reads signed findings, and records what the user thinks of them.
///
/// Reads go straight to the table like every other mobile read, riding the
/// Supabase client the app already holds and keeping the agent invisible to the
/// frontend.
///
/// There is deliberately nothing here that reads `clinical_drafts`. It would
/// not work if there were: the table has no select policy admitting the person
/// a draft is about, so an unreviewed draft is physically unreadable from this
/// device. That is the enforcement, rather than this class remembering not to
/// ask.
///
/// Writes are narrow for the same reason. The app can set `disputed_at`,
/// `dispute_reason` and `dismissed_at` and nothing else — not because this code
/// is careful, but because `revoke update on insights` followed by a
/// column-level grant is all the privilege the role has. An attempt to rewrite
/// `body` or put a name in `reviewed_by` fails at the database with 42501.
class InsightRepository {
  InsightRepository([SupabaseClient? client]) : _client = client;

  final SupabaseClient? _client;

  SupabaseClient? get _db {
    if (!SupabaseConfig.configured) return null;
    return _client ?? Supabase.instance.client;
  }

  /// Columns the app renders. `withdrawn_at` is filtered rather than displayed:
  /// withdrawn means it should not have been sent, and showing it would mean
  /// showing something after it was retracted.
  static const _columns =
      'id,kind,title,body,evidence,noticed_by,reviewed_at,reviewer_name,'
      'reviewer_registration,delivery_route,delivered_at,disputed_at,'
      'dispute_reason,dismissed_at';

  /// This user's findings, newest first.
  ///
  /// An empty list on failure, like the other repositories — but note the
  /// caller must not render "you have no findings" from that alone. "We could
  /// not look" and "there are none" are different statements, which is why
  /// [forUser] returns null rather than an empty list when it could not ask.
  Future<List<ClinicalInsight>?> forUser(String userId) async {
    final db = _db;
    if (db == null) return null;
    try {
      final rows = await db
          .from('insights')
          .select(_columns)
          .eq('user_id', userId)
          .isFilter('withdrawn_at', null)
          .order('delivered_at', ascending: false);
      return ClinicalInsight.parseRows(
        [for (final row in rows) Map<String, dynamic>.from(row)],
      );
    } catch (_) {
      return null;
    }
  }

  /// "I have read this." Not a judgement about whether it was right.
  Future<void> dismiss(String insightId) async {
    final db = _db;
    if (db == null) return;
    await db
        .from('insights')
        .update({'dismissed_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', insightId);
  }

  /// "This is wrong about me." A different statement, and the one that should
  /// reach the clinician who signed it.
  ///
  /// The reason is required. `dispute_carries_a_reason` enforces it in the
  /// database, and a dispute with no reason is a dismissal with a different
  /// label.
  Future<void> dispute(String insightId, String reason) async {
    final db = _db;
    if (db == null) return;
    final trimmed = reason.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(reason, 'reason', 'a dispute needs a reason');
    }
    await db.from('insights').update({
      'disputed_at': DateTime.now().toUtc().toIso8601String(),
      'dispute_reason': trimmed,
    }).eq('id', insightId);
  }
}
