import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/clinical_insight.dart';
import '../providers/insight_provider.dart';
import 'insight_card.dart';

/// Findings a clinician has signed off, and the ones still waiting.
///
/// Drops into a screen as a block. There is nothing here that could show an
/// unreviewed draft — the table has no select policy admitting the person a
/// draft is about, so the device cannot read one even if this widget asked.
class ClinicalInsightsSection extends ConsumerWidget {
  const ClinicalInsightsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(clinicalInsightsProvider);
    final theme = Theme.of(context);

    return state.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      ),
      // Nothing, rather than an error box. A failed read of this section must
      // not be the loudest thing on a screen whose other half is working.
      error: (_, _) => const SizedBox.shrink(),
      data: (insights) {
        // null is "we could not look", which is not "you have none". Saying
        // the second when the first is true is the same mistake as rendering a
        // missing score as a zero.
        if (insights == null) return const SizedBox.shrink();

        final visible = [for (final i in insights) if (i.needsAttention) i];
        if (visible.isEmpty) {
          return _Empty(hasHistory: insights.isNotEmpty);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Clinician findings',
                  style: theme.textTheme.titleLarge),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'What we noticed in your results, and who has checked it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            for (final insight in visible)
              InsightCard(
                key: ValueKey(insight.id),
                insight: insight,
                onDismiss: () => _dismiss(ref, insight),
                onDispute: (reason) => _dispute(ref, insight, reason),
              ),
          ],
        );
      },
    );
  }

  Future<void> _dismiss(WidgetRef ref, ClinicalInsight insight) async {
    await ref.read(insightRepositoryProvider).dismiss(insight.id);
    ref.invalidate(clinicalInsightsProvider);
  }

  Future<void> _dispute(
    WidgetRef ref,
    ClinicalInsight insight,
    String reason,
  ) async {
    await ref.read(insightRepositoryProvider).dispute(insight.id, reason);
    ref.invalidate(clinicalInsightsProvider);
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.hasHistory});

  /// Whether there are dismissed findings behind this. "Nothing new" and
  /// "nothing ever" are different states and read differently to someone
  /// wondering whether the feature works.
  final bool hasHistory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Clinician findings', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            hasHistory
                ? 'Nothing new. You have dealt with everything we noticed.'
                : 'Nothing yet. When we notice something in your results, a '
                    'clinician reviews it and it appears here.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
