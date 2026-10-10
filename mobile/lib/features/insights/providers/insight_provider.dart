import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/insight_repository.dart';
import '../models/clinical_insight.dart';

final insightRepositoryProvider = Provider((ref) => InsightRepository());

/// Findings delivered to this user, newest first.
///
/// `null` means we could not ask — no session, or the read failed. The section
/// renders nothing at all in that case rather than "no findings yet", because
/// telling someone they have no clinician findings when we simply could not
/// look is the same class of mistake as rendering a missing score as zero.
///
/// autoDispose so leaving the screen and coming back refetches. Without it the
/// list keeps whatever it held when a dispute was sent, and the card goes on
/// offering a button the user has already pressed.
final clinicalInsightsProvider =
    FutureProvider.autoDispose<List<ClinicalInsight>?>((ref) async {
  final user = ref.watch(authProvider).asData?.value;
  if (user == null) return null;
  return ref.read(insightRepositoryProvider).forUser(user.id);
});
