import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/providers/auth_provider.dart';
import '../../roles/providers/role_provider.dart';
import '../data/account_repository.dart';
import '../models/account_invitation.dart';

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => AccountRepository(http: ref.watch(apiClientProvider).dio),
);
final pendingInvitationsProvider =
    FutureProvider.autoDispose<List<AccountInvitation>>(
      (ref) => ref.read(accountRepositoryProvider).pending(),
    );
final accountActionsProvider = Provider(AccountActions.new);

class AccountActions {
  AccountActions(this.ref);
  final Ref ref;
  Future<void> accept(String id) async {
    await ref.read(accountRepositoryProvider).accept(id);
    ref.invalidate(pendingInvitationsProvider);
    ref.invalidate(roleProvider);
  }

  Future<void> decline(String id) async {
    await ref.read(accountRepositoryProvider).decline(id);
    ref.invalidate(pendingInvitationsProvider);
  }
}
