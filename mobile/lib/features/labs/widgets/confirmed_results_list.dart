import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/biomarker_result.dart';
import '../providers/lab_provider.dart';

/// Values read from an uploaded report, after the user has confirmed them.
///
/// This exists because without it the feature appeared to do nothing. A user
/// could upload a report, check every value and tap "Add these to my record" —
/// and the screen called "Lab results" would still say *0 Results, no matching
/// lab results*, because its list reads hand-typed journal entries and knows
/// nothing about what was extracted. The data was stored correctly and shown
/// nowhere.
///
/// **No verdicts here.** Every result arrives `ungraded` until a clinician has
/// signed the reference ranges off, so there are no colours, no high/low
/// markers and no reference column — the value as the report printed it, and
/// where it came from. The hand-typed list below does show ranges, because
/// those are ranges the user typed themselves and took responsibility for.
class ConfirmedResultsList extends ConsumerWidget {
  const ConfirmedResultsList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final results = ref.watch(confirmedResultsProvider);

    return results.when(
      loading: () => const SizedBox.shrink(),
      // "We could not look" is not "you have none", so this says so rather
      // than rendering an empty list.
      error: (_, _) => Text(
        'We could not load your confirmed results just now.',
        style: theme.textTheme.bodySmall,
      ),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            Text('From your reports', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Read from the reports you uploaded and confirmed.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            for (final result in list) _ResultRow(result: result),
          ],
        );
      },
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.result});

  final BiomarkerResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(result.displayLabel),
        subtitle: Text(
          [
            if (result.collectedAt != null)
              DateFormat.yMMMd().format(result.collectedAt!),
            if (result.isCensored)
              'outside what the lab could measure, so not used in calculations',
          ].join(' · '),
          style: theme.textTheme.bodySmall,
        ),
        trailing: Text(
          result.displayValueWithUnit,
          style: theme.textTheme.titleMedium,
        ),
      ),
    );
  }
}
