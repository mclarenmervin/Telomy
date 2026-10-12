import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/account_repository.dart';
import '../models/account_invitation.dart';
import '../providers/account_provider.dart';

class PendingInvitationScreen extends ConsumerWidget {
  const PendingInvitationScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(pendingInvitationsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Account invitations')),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error is AccountUnavailable
                    ? error.message
                    : 'Invitations could not be read just now.',
              ),
              FilledButton(
                onPressed: () => ref.invalidate(pendingInvitationsProvider),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
        data: (items) => items.isEmpty
            ? const Center(child: Text('No pending invitations'))
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (_, index) =>
                    _InvitationCard(invitation: items[index]),
              ),
      ),
    );
  }
}

class _InvitationCard extends ConsumerStatefulWidget {
  const _InvitationCard({required this.invitation});
  final AccountInvitation invitation;
  @override
  ConsumerState<_InvitationCard> createState() => _InvitationCardState();
}

class _InvitationCardState extends ConsumerState<_InvitationCard> {
  bool busy = false;
  String? error;
  Future<void> decide(bool accept) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final actions = ref.read(accountActionsProvider);
      if (accept) {
        await actions.accept(widget.invitation.id);
      } else {
        await actions.decline(widget.invitation.id);
      }
    } on AccountUnavailable catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final invitation = widget.invitation;
    final expired =
        invitation.status == InvitationStatus.expired ||
        (invitation.expiresAt?.isBefore(DateTime.now()) ?? false);
    final status = expired
        ? 'Expired'
        : invitation.status == InvitationStatus.revoked
        ? 'Revoked'
        : invitation.status.name;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              invitation.role.label,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(status[0].toUpperCase() + status.substring(1)),
            if (invitation.requiresVerification)
              const Text('Clinical access starts after licence verification.'),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (invitation.actionable)
              Row(
                children: [
                  FilledButton(
                    onPressed: busy ? null : () => decide(true),
                    child: const Text('Accept'),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => decide(false),
                    child: const Text('Decline'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
