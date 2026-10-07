import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/lab_escalation.dart';
import '../providers/lab_provider.dart';

/// Puts a critical lab value in front of the person.
///
/// The worker writes these before anything is confirmed and regardless of
/// review state, because the clinician queue is for recommendations and never
/// for emergencies. None of that counted for anything while no screen read the
/// table: a finding nobody sees has not escalated.
///
/// The message is rendered exactly as the server wrote it. It is deliberately
/// non-diagnostic — the ranges it fired on have not been reviewed by a
/// clinician — and composing a second version of that sentence here would be a
/// second place to get it wrong.
class EscalationBanner extends ConsumerWidget {
  const EscalationBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final escalations = ref.watch(outstandingEscalationsProvider);

    return escalations.maybeWhen(
      data: (list) => list.isEmpty
          ? const SizedBox.shrink()
          : Column(
              children: [
                for (final e in list) _Banner(escalation: e),
              ],
            ),
      // Nothing on failure. A banner that says "we could not check" on every
      // cold start would be noise, and noise is how a real one gets ignored.
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _Banner extends ConsumerWidget {
  const _Banner({required this.escalation});

  final LabEscalation escalation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('lab-escalation-banner'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 8),
              Text(
                'Please get this checked',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            escalation.message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('lab-escalation-ack'),
              onPressed: () async {
                await ref
                    .read(labRepositoryProvider)
                    .acknowledgeEscalation(escalation.id);
                ref.invalidate(outstandingEscalationsProvider);
              },
              // "Seen", not "Dismiss": the finding stays on the record and the
              // user is only saying they have read it.
              child: const Text('I have seen this'),
            ),
          ),
        ],
      ),
    );
  }
}
