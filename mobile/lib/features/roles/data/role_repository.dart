import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/app_role.dart';

/// Reads this person's own platform role.
///
/// **It takes no user id.** The same rule the agent's tools follow and the
/// gateway's `current_user_id` follows: the subject comes from the session, so
/// asking for somebody else's role is not a thing this class can express. The
/// `profiles` select policy would refuse it anyway — a member reads their own
/// row and nothing else — but a method that *could* ask would be a method
/// somebody eventually calls with an id from a list.
abstract class RoleRepository {
  Future<AppRole> mine();
}

class SupabaseRoleRepository implements RoleRepository {
  SupabaseRoleRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<AppRole> mine() async {
    final user = _client.auth.currentUser;
    if (user == null) return AppRole.member;

    // `maybeSingle`, not `single`: a profile row can legitimately be absent
    // for a moment after signup, before `handle_new_user` has run, and that
    // is not an error worth throwing at somebody opening the app.
    final row = await _client
        .from('profiles')
        .select('app_role')
        .eq('id', user.id)
        .maybeSingle();

    return AppRole.parse(row?['app_role'] as String?);
  }
}

/// For builds with no Supabase project configured, and for tests.
class FixedRoleRepository implements RoleRepository {
  const FixedRoleRepository(this.role);

  final AppRole role;

  @override
  Future<AppRole> mine() async => role;
}
