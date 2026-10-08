import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../../scores/providers/score_provider.dart';
import '../data/biological_age_view.dart';
import '../data/epigenetic_repository.dart';
import '../models/epigenetic_clock.dart';

/// The score kind this feature reads. Matches `score_snapshots.score_kind`.
const biologicalAgeKind = 'biological_age';

final epigeneticRepositoryProvider = Provider((ref) => EpigeneticRepository());

/// The biological age the server computed, as a view the screen can render.
///
/// Unlike readiness there is no `day` argument and no local fallback. The
/// snapshot is dated to the blood draw, so there is no "today's" biological
/// age to ask for -- asking for one would either return nothing or invent a
/// date. The newest snapshot is the answer, whatever day it belongs to.
final biologicalAgeProvider = FutureProvider<BiologicalAgeView>((ref) async {
  final user = ref.watch(authProvider).asData?.value;
  if (user == null) {
    return const BiologicalAgeView(state: BiologicalAgeState.notComputed);
  }
  final snapshot = await ref
      .read(scoreRepositoryProvider)
      .latestSnapshot(userId: user.id, kind: biologicalAgeKind);
  return BiologicalAgeView.of(snapshot);
});

/// Third-party clocks the user has told us about. Ours and theirs are kept in
/// separate providers because they are separate claims.
final epigeneticClocksProvider =
    FutureProvider<List<EpigeneticClock>>((ref) async {
  final user = ref.watch(authProvider).asData?.value;
  if (user == null) return const [];
  return ref.read(epigeneticRepositoryProvider).forUser(user.id);
});
