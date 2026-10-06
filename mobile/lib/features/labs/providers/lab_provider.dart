import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/lab_repository.dart';
import '../models/biomarker_result.dart';
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
final labUploadsProvider = FutureProvider<List<LabUpload>>((ref) async {
  final user = ref.watch(authProvider).asData?.value;
  if (user == null) return const [];
  return ref.read(labRepositoryProvider).uploads(userId: user.id);
});

/// The values read off one report, for the confirmation screen.
final labResultsProvider =
    FutureProvider.family<List<BiomarkerResult>, String>((ref, uploadId) async {
  final user = ref.watch(authProvider).asData?.value;
  if (user == null) return const [];
  return ref
      .read(labRepositoryProvider)
      .resultsFor(userId: user.id, uploadId: uploadId);
});
