import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/therapy_repository.dart';
import '../models/therapy_effect.dart';
import '../models/therapy_catalogue.dart';

final therapyRepositoryProvider = Provider(
  (ref) => TherapyRepository(http: ref.watch(apiClientProvider).dio),
);

/// Worked out again each time the screen is opened.
///
/// `autoDispose`, like the correlations report and for the reason the
/// emulator demonstrated there: a screen whose common early answer is "not
/// enough sessions yet" must be able to stop saying it once the sessions
/// have happened.
final therapyEffectsProvider =
    FutureProvider.autoDispose<TherapyEffectReport>((ref) async {
  return ref.read(therapyRepositoryProvider).effects();
});

final therapyCatalogueProvider = FutureProvider.autoDispose<List<TherapyCatalogueItem>>(
  (ref) => ref.read(therapyRepositoryProvider).catalogue(),
);

final therapyOfferingsProvider = FutureProvider.autoDispose.family<List<TherapyOffering>, String>(
  (ref, centreId) => ref.read(therapyRepositoryProvider).offerings(centreId),
);
