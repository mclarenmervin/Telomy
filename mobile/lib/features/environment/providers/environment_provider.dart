import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../../journal/providers/wellness_provider.dart';
import '../data/coarse_places.dart';
import '../data/environment_repository.dart';
import '../models/environment_snapshot.dart';

/// The profile keys the server reads. Spelled here once so the screen cannot
/// invent a third spelling: `app/analytics/environment.py` looks for exactly
/// these, and a typo would be a feature that silently never runs.
const consentLocationKey = 'consentLocation';
const coarseLatitudeKey = 'coarseLatitude';
const coarseLongitudeKey = 'coarseLongitude';

/// The app's convention for yes, shared by every consent in the product.
/// `user_preferences.profile` is a `Map<String, String>`, so this is the
/// string and not the boolean — the server accepts both, having been caught
/// out once by accepting only the boolean.
const consentYes = 'true';

final environmentRepositoryProvider = Provider(
  (ref) => EnvironmentRepository(http: ref.watch(apiClientProvider).dio),
);

/// Where the user said they are, if they have said.
final chosenPlaceProvider = Provider<CoarsePlace?>((ref) {
  final profile = ref.watch(wellnessProvider).asData?.value.profile ?? const {};
  if (profile[consentLocationKey] != consentYes) return null;
  return placeAt(
    double.tryParse(profile[coarseLatitudeKey] ?? ''),
    double.tryParse(profile[coarseLongitudeKey] ?? ''),
  );
});

/// The last fortnight of conditions.
///
/// autoDispose, like the other three F8 reads: the first snapshot does not
/// arrive until the night after somebody sets a location, and a cached
/// "nothing yet" would outlive it.
final environmentProvider =
    FutureProvider.autoDispose<List<EnvironmentSnapshot>>((ref) async {
  // Re-read when the place changes, so clearing a location empties the
  // screen rather than leaving yesterday's city on it.
  ref.watch(chosenPlaceProvider);
  return ref.read(environmentRepositoryProvider).recent();
});

/// Save, or clear, the coarse location.
///
/// Clearing writes `false` and removes the coordinates rather than only
/// flipping the flag. A latitude left behind after somebody withdrew consent
/// is data we were asked not to hold.
Future<void> setCoarseLocation(WidgetRef ref, CoarsePlace? place) async {
  final controller = ref.read(wellnessProvider.notifier);
  final profile = Map<String, String>.from(
    ref.read(wellnessProvider).asData?.value.profile ?? const {},
  );

  if (place == null) {
    profile[consentLocationKey] = 'false';
    profile.remove(coarseLatitudeKey);
    profile.remove(coarseLongitudeKey);
  } else {
    profile[consentLocationKey] = consentYes;
    profile[coarseLatitudeKey] = place.latitude.toString();
    profile[coarseLongitudeKey] = place.longitude.toString();
  }

  await controller.saveProfile(profile);
  ref.invalidate(environmentProvider);
}
