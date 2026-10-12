import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/genetics_repository.dart';
import '../models/genetic_upload.dart';

final geneticsRepositoryProvider = Provider((ref) => GeneticsRepository());

/// This person's imports and the variants that survived them.
///
/// `autoDispose`, like the correlations and therapy reports, and for the
/// reason the emulator taught on the first of those: an import finishes
/// seconds after the upload, and a provider that cached its first answer
/// would say "Reading your file…" until the app was restarted.
final geneticsProvider =
    FutureProvider.autoDispose<GeneticsView>((ref) async {
  final user = ref.watch(authProvider).asData?.value;
  if (user == null) return const GeneticsView(uploads: [], variants: []);
  final repository = ref.read(geneticsRepositoryProvider);
  return GeneticsView(
    uploads: await repository.uploads(userId: user.id),
    variants: await repository.variants(userId: user.id),
  );
});

/// What the genetics screen renders.
class GeneticsView {
  const GeneticsView({required this.uploads, required this.variants});

  final List<GeneticUpload> uploads;
  final List<StoredVariant> variants;

  bool get hasAnything => uploads.isNotEmpty || variants.isNotEmpty;

  /// An import the server has not finished. The screen polls while this is
  /// true rather than leaving somebody looking at a spinner that never
  /// resolves — the defect F3 shipped on the lab tile.
  bool get isImporting => uploads.any((upload) => upload.isInFlight);
}
