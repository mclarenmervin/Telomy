import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/correlation_repository.dart';
import '../models/correlation.dart';
import '../providers/correlation_provider.dart';

/// Patterns between this person's own daily series.
///
/// Everything on this screen was decided on the server. The phone used to run
/// its own Pearson across forty-five pairs with no multiple-comparison
/// correction, accept five matching days, and label the result "Strong
/// pattern · move together" — which is a confident sentence about somebody's
/// body with nothing behind it.
///
/// Two things this screen is careful about. It shows what was *tested* and
/// not only what held, because "none of the five we tested held" is a result
/// and "nothing found" reads like a broken feature. And it never explains a
/// pattern unless a clinician has signed the explanation off; today none are
/// signed, so it says two things moved together and stops.
class CorrelationsScreen extends ConsumerWidget {
  const CorrelationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final days = ref.watch(correlationWindowProvider);
    final report = ref.watch(correlationReportProvider);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Correlations', style: theme.textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text(
          'Patterns between health signals recorded on the same days. We only '
          'test pairs there is a known reason to expect a link between.',
        ),
        const SizedBox(height: 18),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 30, label: Text('30 days')),
            ButtonSegment(value: 60, label: Text('60 days')),
            ButtonSegment(value: 90, label: Text('90 days')),
          ],
          selected: {days},
          onSelectionChanged: (value) =>
              ref.read(correlationWindowProvider.notifier).setDays(value.first),
        ),
        const SizedBox(height: 22),
        ...report.when(
          loading: () => [const LinearProgressIndicator()],
          error: (error, _) => [
            _Unavailable(
              message: error is CorrelationsUnavailable
                  ? error.message
                  : 'These patterns could not be worked out just now.',
              onRetry: () => ref.invalidate(correlationReportProvider),
            ),
          ],
          data: (data) => _results(context, data),
        ),
      ],
    );
  }

  List<Widget> _results(BuildContext context, CorrelationReport report) {
    return [
      if (report.tested == 0)
        const _Note(
          key: Key('correlations-nothing-tested'),
          text: 'There is not enough recorded yet to test any pattern. These '
              'need at least two weeks of days with both signals recorded.',
        )
      else if (report.isEmpty)
        _Note(
          key: const Key('correlations-none-held'),
          text: 'We tested ${report.tested} '
              '${report.tested == 1 ? 'pattern' : 'patterns'} over the last '
              '${report.windowDays} days and none of them held up. That is a '
              'result, not a gap.',
        ),
      for (final result in report.reported)
        _ReportedCard(key: Key('correlation-${result.pairId}'), result: result),
      if (report.withheld.isNotEmpty) ...[
        const SizedBox(height: 18),
        _WithheldSection(report: report),
      ],
      const SizedBox(height: 12),
      const _Note(
        text: 'Correlation shows that two recorded values changed together. It '
            'does not show that one caused the other, and changing one will '
            'not necessarily change the other. Missing records, timing, '
            'medication and illness all affect these patterns.',
      ),
    ];
  }
}

class _ReportedCard extends StatelessWidget {
  const _ReportedCard({super.key, required this.result});

  final Correlation result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coefficient = result.coefficient ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${seriesLabel(result.first)} & ${seriesLabel(result.second)}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(coefficient.toStringAsFixed(2)),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: coefficient.abs(),
              color: coefficient >= 0
                  ? theme.colorScheme.primary
                  : theme.colorScheme.tertiary,
            ),
            const SizedBox(height: 10),
            // Deliberately no "Strong" / "Moderate" / "Weak" label. The old
            // screen printed one from the coefficient alone, which says
            // nothing about whether the pattern is real.
            Text(
              'They ${result.direction} · ${result.pairedDays} matching days',
              style: theme.textTheme.bodyMedium,
            ),
            if (result.mechanism != null) ...[
              const SizedBox(height: 10),
              Text(result.mechanism!, style: theme.textTheme.bodySmall),
            ] else ...[
              const SizedBox(height: 10),
              Text(
                'We have not had a clinician review why these two move '
                'together, so we are not going to tell you.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What was tested and did not qualify.
///
/// Collapsed, but present. Hiding it would leave the screen unable to
/// distinguish "we looked and found nothing" from "we did not look", and the
/// reason a pair was refused is often the most honest thing on the page.
class _WithheldSection extends StatelessWidget {
  const _WithheldSection({required this.report});

  final CorrelationReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ExpansionTile(
        key: const Key('correlations-withheld'),
        title: Text(
          'Also tested, not shown (${report.withheld.length})',
          style: theme.textTheme.titleSmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
        children: [
          for (final result in report.withheld)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${seriesLabel(result.first)} & ${seriesLabel(result.second)}',
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    withheldReason(result.withheld ?? '', report.windowDays),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('correlations-unavailable'),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            const SizedBox(height: 10),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(padding: const EdgeInsets.all(18), child: Text(text)),
      );
}
