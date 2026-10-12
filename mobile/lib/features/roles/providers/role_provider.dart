import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/supabase_config.dart';
import '../../auth/providers/auth_provider.dart';
import '../data/role_repository.dart';
import '../models/app_role.dart';

final roleRepositoryProvider = Provider<RoleRepository>((ref) {
  if (!SupabaseConfig.configured) {
    // A build with no project configured is the member app. Not an error —
    // the demo and the widget tests both run this way — and not an admin
    // either, which is the direction that would matter.
    return const FixedRoleRepository(AppRole.member);
  }
  return SupabaseRoleRepository(Supabase.instance.client);
});

/// This person's platform role, or null while it is being read.
///
/// `autoDispose` and keyed on the session: signing out and back in as
/// somebody else must re-read the column rather than leave the previous
/// account's role in place. That is the F8 report's `FutureProvider` lesson —
/// "will keep telling a user 'not enough data yet' for the life of the app
/// after the data arrives", which has now cost two screens — pointed at the
/// one piece of state where staleness decides which app you see.
final roleProvider = FutureProvider.autoDispose<AppRole>((ref) async {
  final user = ref.watch(authProvider).asData?.value;
  if (user == null) return AppRole.member;
  return ref.read(roleRepositoryProvider).mine();
});
