import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/lab_repository.dart';
import '../models/lab_upload.dart';

/// Reads ride the Supabase client; the confirm call needs the authenticated Dio
/// instance, because it is the one write that goes through our API.
final labRepositoryProvider = Provider(
  (ref) => LabRepository(http: ref.watch(apiClientProvider).dio),
);

/// The user's reports, newest first.
///
/// An empty list when nobody is signed in rather than an error: this renders
/// inside a tab that can be built before the session resolves.
/// autoDispose so leaving the screen and coming back refetches. Without it the
/// list keeps the value it had when the upload started, which on a real device
/// meant the tile said "Reading the report..." indefinitely.
final labUploadsProvider = FutureProvider.autoDispose<List<LabUpload>>((ref) async {
  final user = ref.watch(authProvider).asData?.value;
  if (user == null) return const [];
  return ref.read(labRepositoryProvider).uploads(userId: user.id);
});

/// Everything the confirmation screen needs for one report.
final labReviewProvider =
    FutureProvider.autoDispose.family<LabReview, String>((ref, uploadId) async {
  return ref.read(labRepositoryProvider).review(uploadId: uploadId);
});
