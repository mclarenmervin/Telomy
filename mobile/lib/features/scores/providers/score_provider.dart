import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/score_repository.dart';
import '../data/shadow_log.dart';
import '../models/score_snapshot.dart';

final scoreRepositoryProvider = Provider((ref) => ScoreRepository());

/// Lives for the app session. The shadow window is measured in days, and this
/// only needs to answer "have we seen a disagreement" while someone is looking.
final shadowLogProvider = Provider((ref) => ShadowLog());

/// The server's snapshot for a day, or null when it has not computed one.
///
/// Null is a real answer and the caller must not turn it into a zero.
final serverScoreProvider =
    FutureProvider.family<ScoreSnapshot?, ({String kind, DateTime day})>(
  (ref, args) async {
    final user = ref.watch(authProvider).asData?.value;
    if (user == null) return null;
    return ref.read(scoreRepositoryProvider).snapshotFor(
          userId: user.id,
          kind: args.kind,
          day: args.day,
        );
  },
);
