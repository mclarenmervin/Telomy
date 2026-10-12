import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/vocabulary.dart';
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
///
/// F9 rebuilt it on the shared vocabulary. The provenance sentence it had
/// written by hand — "They move together · 60 matching days" — is now a
/// [Prov], and the effective sample size travels with it, which the
/// hand-written version never showed.
class CorrelationsScreen extends ConsumerWidget {
  const CorrelationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(correlationWindowProvider);
    final report = ref.watch(correlationReportProvider);

    return AppScreen(
      title: 'Correlations',
      onRefresh: () async => ref.invalidate(correlationReportProvider),
      children: [
        const T(
          'Patterns between health signals recorded on the same days. We only '
          'test pairs there is a known reason to expect a link between.',
          muted: true,
        ),
        const SizedBox(height: AppSpacing.md),
        Segmented<int>(
          options: const {30: '30 days', 60: '60 days', 90: '90 days'},
          selected: days,
          onChanged: (value) =>
              ref.read(correlationWindowProvider.notifier).setDays(value),
        ),
        const SizedBox(height: AppSpacing.lg),
        ...report.when(
          loading: () =>
              [const Loading('Working out what moved together…')],
          error: (error, _) => [
            ErrorState(
              key: const Key('correlations-unavailable'),
              message: error is CorrelationsUnavailable
                  ? error.message
                  : 'These patterns could not be worked out just now.',
              onRetry: () => ref.invalidate(correlationReportProvider),
            ),
          ],
          data: (data) => _results(data),
        ),
      ],
    );
  }

  List<Widget> _results(CorrelationReport report) {
    return [
      if (report.tested == 0)
        const Empty(
          key: Key('correlations-nothing-tested'),
          title: 'Nothing to test yet',
          body: 'These need at least two weeks of days with both signals '
              'recorded. Keep your ring on and they will start appearing.',
          tone: EmptyTone.waiting,
        )
      else if (report.isEmpty)
        Empty(
          key: const Key('correlations-none-held'),
          // A result, and it renders as one. This is the screen F12's therapy
          // tab will live in and the component had to be built for it.
          tone: EmptyTone.result,
          title: 'Nothing held up',
          body: 'We tested ${report.tested} '
              '${report.tested == 1 ? 'pattern' : 'patterns'} over the last '
              '${report.windowDays} days and none of them held up. That is a '
              'result, not a gap.',
        ),
      for (final result in report.reported)
        _ReportedCard(key: Key('correlation-${result.pairId}'), result: result),
      if (report.withheld.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.md),
        _WithheldSection(report: report),
      ],
      const SizedBox(height: AppSpacing.sm),
      const AppCard(
        child: T(
          'Correlation shows that two recorded values changed together. It '
          'does not show that one caused the other, and changing one will '
          'not necessarily change the other. Missing records, timing, '
          'medication and illness all affect these patterns.',
          v: TextVariant.small,
          muted: true,
        ),
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

    // The effective sample size, not the day count, is the honest figure.
    // Over 200 trials of two independent 60-day random walks, 141 cleared
    // p < 0.05 with |r| >= 0.3 on the raw day count and 7 did on the
    // effective one. Both are shown: the day count is what the person
    // recognises, the effective count is what the test actually used.
    final effective = result.effectiveDays;
    final basis = effective == null
        ? '${result.pairedDays} matching days'
        : '${result.pairedDays} matching days · '
            '${effective.toStringAsFixed(0)} independent';

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: T(
                  '${seriesLabel(result.first)} & ${seriesLabel(result.second)}',
                  v: TextVariant.h3,
                ),
              ),
              T(coefficient.toStringAsFixed(2), v: TextVariant.num),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          ConfBar(
            confidence: result.mechanismReviewed
                ? Confidence.measured
                : Confidence.unreviewed,
            basis: basis,
          ),
          const SizedBox(height: AppSpacing.xs),
          LinearProgressIndicator(
            value: coefficient.abs(),
            color: coefficient >= 0
                ? theme.colorScheme.primary
                : theme.colorScheme.tertiary,
          ),
          const SizedBox(height: AppSpacing.xs),
          // Deliberately no "Strong" / "Moderate" / "Weak" label. The old
          // screen printed one from the coefficient alone, which says
          // nothing about whether the pattern is real.
          T('They ${result.direction}.'),
          Prov(
            source: 'your own ${result.pairedDays} days of records',
            whenLabel: 'the last ${result.pairedDays} days with both',
            confidence: result.mechanismReviewed
                ? Confidence.measured
                : Confidence.unreviewed,
            basis: basis,
          ),
          if (result.mechanism != null) ...[
            const SizedBox(height: AppSpacing.xs),
            T(result.mechanism!, v: TextVariant.small),
          ] else ...[
            const SizedBox(height: AppSpacing.xs),
            // Not "we are not going to tell you", which was the first
            // wording and read on a real screen as a product being
            // withholding rather than careful. And not "move together"
            // either: this card is shown for correlations that move
            // oppositely, where it would contradict the line above it.
            const T(
              'Nobody has reviewed why these two are related, so we are '
              'not going to guess at it.',
              v: TextVariant.small,
              muted: true,
            ),
          ],
        ],
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
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: ExpansionTile(
        key: const Key('correlations-withheld'),
        tilePadding: EdgeInsets.zero,
        title: T('Also tested, not shown (${report.withheld.length})',
            v: TextVariant.h3),
        childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
        children: [
          for (final result in report.withheld)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  T('${seriesLabel(result.first)} & ${seriesLabel(result.second)}'),
                  T(
                    withheldReason(result.withheld ?? '', report.windowDays),
                    v: TextVariant.small,
                    muted: true,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
