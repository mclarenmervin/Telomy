import 'package:flutter/material.dart';

import '../data/longitudinal_insight_service.dart';

/// Patterns computed on this phone, from records already on it.
///
/// Labelled, because the architecture rule this programme follows is that
/// Postgres holds facts, Python computes and Flutter renders — and the one
/// exception is a *visibly labelled* offline estimate that is never written
/// back. An unlabelled phone-computed narrative sitting beside server answers
/// is the dual-math defect on a single screen: two numbers, two methods, no
/// way for the reader to know which they are looking at.
class LocalPatternsSection extends StatelessWidget {
  const LocalPatternsSection({super.key, required this.insights});

  final List<LongitudinalInsight> insights;

  @override
  Widget build(BuildContext context) {
    if (insights.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Column(
      key: const Key('chat-local-patterns'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 36),
        Text('Patterns from this phone', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Calculated here from your saved records, without asking the server. '
          'They describe recorded patterns only — they do not identify causes '
          'or diagnose anything.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        for (final insight in insights)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_icon(insight.direction), size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(insight.title, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(insight.summary, style: theme.textTheme.bodySmall),
                      Text(
                        '${insight.evidence} · ${insight.sampleDays} recorded days',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  IconData _icon(InsightDirection direction) => switch (direction) {
        InsightDirection.improving => Icons.trending_up,
        InsightDirection.declining => Icons.trending_down,
        InsightDirection.stable => Icons.trending_flat,
        InsightDirection.neutral => Icons.insights_outlined,
      };
}
