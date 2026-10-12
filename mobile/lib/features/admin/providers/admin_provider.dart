import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/admin_repository.dart';
import '../models/catalogue_entry.dart';
import '../models/platform_health.dart';

final adminRepositoryProvider = Provider(
  (ref) => AdminRepository(http: ref.watch(apiClientProvider).dio),
);

/// autoDispose on all three, like every other read added since F8. A cached
/// `stranded_total` is worse than a slow one: the number's whole purpose is to
/// be current, and an admin looking at a stale zero would conclude the queue
/// had been cleared.
final platformHealthProvider = FutureProvider.autoDispose<PlatformHealth>(
  (ref) => ref.read(adminRepositoryProvider).platform(),
);

final catalogueProvider =
    FutureProvider.autoDispose<List<ReviewableCatalogue>>(
  (ref) => ref.read(adminRepositoryProvider).catalogue(),
);

final auditProvider = FutureProvider.autoDispose<List<AdminAction>>(
  (ref) => ref.read(adminRepositoryProvider).audit(),
);
