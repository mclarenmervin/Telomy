import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/vocabulary.dart';
import '../data/therapy_repository.dart';
import '../models/therapy_effect.dart';
import '../providers/therapy_provider.dart';

/// What this person's own sessions did to them, above the list of sessions.
///
/// The therapy screen has always been a list of things the user typed. This
/// is the half that reads them back: across a run of sessions, the hour after
/// against the hour before.
///
/// Two things it is careful to say. Everything here is the hour after a
/// session and says nothing about whether a therapy is working over months —
/// for several of these signals the long-term effect runs the opposite way,
/// so the screen states the limit rather than leaving the reader to assume.
/// And it never explains a change unless a clinician has signed the
/// explanation off, which today is never.
///
/// F9 moved its hand-written provenance — "Across 8 sessions — 2 more were
/// left out because something else you logged overlapped them" — into [Prov].
/// Both halves survived the move: the count is the basis, and the confounded
/// sessions are still accounted for, because that is why the number is lower
/// than the number of sessions somebody remembers doing.
class TherapyEffectsSection extends ConsumerWidget {
  const TherapyEffectsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(therapyEffectsProvider);

    return Column(
      key: const Key('therapy-effects'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Section(
          title: 'What your sessions do',
          blurb:
              'Measured in the hour after each session against the hour '
              'before, across all the sessions you have logged.',
          children: [
            ...report.when(
              loading: () => [const Loading('Measuring your sessions…')],
              error: (error, _) => [
                ErrorState(
                  message: error is TherapyEffectsUnavailable
                      ? error.message
                      : 'This could not be worked out just now.',
                  onRetry: () => ref.invalidate(therapyEffectsProvider),
                ),
              ],
              data: (data) => _results(data),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        const Divider(),
      ],
    );
  }

  List<Widget> _results(TherapyEffectReport report) {
    if (report.verdicts.isNotEmpty) {
      return [
        for (final effect in report.verdicts)
          TherapyVerdictCard(effect: effect),
        const SizedBox(height: AppSpacing.xs),
        const T(
          'These are associations in your readings around sessions, not proof that a therapy caused a change.',
          v: TextVariant.small,
          muted: true,
        ),
      ];
    }
    return [
      if (report.tested == 0 && report.withheld.isEmpty)
        Empty(
          key: const Key('therapy-effects-none'),
          title: 'Not enough sessions yet',
          body:
              'Once you have logged a few sauna or cold plunge sessions '
              'with your ring on, we will measure what they do to you. It '
              'takes ${report.minSessions} before a run means anything.',
          tone: EmptyTone.waiting,
        )
      // Measured, and nothing qualified. Found by a test: with `tested` above
      // zero and nothing in either list, this section rendered as a title and
      // a blank space. Three phases from now "no reliable signal" is the
      // commonest state on this tab, and a blank space is how it comes to
      // read as a broken feature.
      else if (report.reported.isEmpty && report.withheld.isEmpty)
        Empty(
          key: const Key('therapy-effects-nothing-qualified'),
          tone: EmptyTone.result,
          title: 'No reliable signal yet',
          body:
              'We measured ${report.tested} '
              '${report.tested == 1 ? 'effect' : 'effects'} and none of them '
              'reached the bar. It takes ${report.minSessions} sessions '
              'before a run means anything, and a clear result needs more '
              'than that. That is a result, not a gap.',
        ),
      for (final effect in report.reported) _EffectCard(effect: effect),
      if (report.withheld.isNotEmpty) _WithheldSection(report: report),
      if (report.reported.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.xs),
        const T(
          'This is what happens in the hour afterwards. It does not say '
          'whether the therapy is doing you good over months — for several of '
          'these signals the long-term effect runs the other way, and we '
          'cannot measure that yet.',
          v: TextVariant.small,
          muted: true,
        ),
      ],
    ];
  }
}

String therapyVerdictTitle(TherapyVerdict verdict) => switch (verdict) {
  TherapyVerdict.helped => 'Helped in your data',
  TherapyVerdict.promising => 'Promising pattern',
  TherapyVerdict.possibleNegative => 'Possible negative pattern',
  TherapyVerdict.noReliableSignal => 'No reliable signal',
  TherapyVerdict.tooEarly => 'Too early to tell',
  TherapyVerdict.inSessionOnly => 'In-session only',
};

String _therapyVerdictBody(TherapyEffect effect) => switch (effect.verdict) {
  TherapyVerdict.helped =>
    'The expected change held across both halves of your sessions and passed the evidence threshold.',
  TherapyVerdict.promising =>
    'The change is clear enough to keep watching, but it has not replicated strongly enough to call helped.',
  TherapyVerdict.possibleNegative =>
    'The measured change ran in an adverse direction. Pause and discuss it with your care team.',
  TherapyVerdict.noReliableSignal =>
    'Your readings did not show a stable change. That is a complete result, not missing data.',
  TherapyVerdict.tooEarly =>
    'There are fewer than five eligible sessions, so individual experiences still outweigh the pattern.',
  TherapyVerdict.inSessionOnly =>
    'Your check-ins are available, but there is not enough wearable coverage for a measured outcome.',
};

class TherapyVerdictCard extends StatelessWidget {
  const TherapyVerdictCard({super.key, required this.effect});
  final TherapyEffect effect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final adverse = effect.verdict == TherapyVerdict.possibleNegative;
    final icon = switch (effect.verdict) {
      TherapyVerdict.helped => Icons.check_circle_outline,
      TherapyVerdict.promising => Icons.trending_up,
      TherapyVerdict.possibleNegative => Icons.trending_down,
      TherapyVerdict.noReliableSignal => Icons.horizontal_rule,
      TherapyVerdict.tooEarly => Icons.more_time,
      TherapyVerdict.inSessionOnly => Icons.self_improvement,
    };
    return AppCard(
      key: Key('therapy-verdict-${effect.verdict.wire}'),
      tone: adverse ? CardTone.copper : CardTone.teal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: adverse
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: T(
                  therapyVerdictTitle(effect.verdict),
                  v: TextVariant.h3,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          T('${metricLabel(effect.metric)} after ${effect.label}', muted: true),
          const SizedBox(height: AppSpacing.xs),
          T(_therapyVerdictBody(effect)),
          if (effect.meanDelta != null) ...[
            const SizedBox(height: AppSpacing.sm),
            T(
              'Average change ${effect.meanDelta!.toStringAsFixed(1)} ${metricUnit(effect.metric)} · ${effect.sessions} sessions',
              v: TextVariant.small,
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          const T(
            'This is an association in your readings, not proof of cause.',
            v: TextVariant.small,
            muted: true,
          ),
          if (effect.nextMilestone.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            T(effect.nextMilestone, v: TextVariant.small),
          ],
          if (effect.provenance.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            T(
              'Evidence: ${effect.provenance['model_version'] ?? 'versioned therapy model'}',
              v: TextVariant.small,
              muted: true,
            ),
          ],
        ],
      ),
    );
  }
}

class _EffectCard extends StatelessWidget {
  const _EffectCard({required this.effect});

  final TherapyEffect effect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // The confounded count rides along with the session count rather than
    // sitting in its own sentence. It is the reason the figure is lower than
    // the number of sessions the person remembers doing, so it belongs
    // beside the number and not under it.
    final basis = effect.sessionsConfounded > 0
        ? 'across ${effect.sessions} '
              '${effect.sessions == 1 ? 'session' : 'sessions'}, '
              '${effect.sessionsConfounded} more left out'
        : 'across ${effect.sessions} '
              '${effect.sessions == 1 ? 'session' : 'sessions'}';

    return AppCard(
      key: Key('therapy-effect-${effect.modality}-${effect.metric}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          T(
            '${metricLabel(effect.metric)} after ${effect.label}',
            v: TextVariant.h3,
          ),
          const SizedBox(height: AppSpacing.xxs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Icon(
                effect.rose ? Icons.north_rounded : Icons.south_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.xxs),
              T(
                '${effect.meanDelta!.abs().toStringAsFixed(1)} '
                '${metricUnit(effect.metric)} '
                '${effect.rose ? 'higher' : 'lower'}',
                v: TextVariant.h3,
              ),
            ],
          ),
          Prov(
            source: 'your own sessions',
            whenLabel: 'the hour after each, against the hour before',
            confidence: effect.mechanismReviewed
                ? Confidence.measured
                : Confidence.unreviewed,
            basis: basis,
          ),
          if (effect.sessionsConfounded > 0) ...[
            const SizedBox(height: AppSpacing.xxs),
            T(
              '${effect.sessionsConfounded} '
              '${effect.sessionsConfounded == 1 ? 'session was' : 'sessions were'} '
              'left out because something else you logged overlapped them.',
              v: TextVariant.small,
              muted: true,
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          T(
            effect.mechanism ??
                'Nobody has reviewed why this happens, so we are not going '
                    'to guess at it.',
            v: TextVariant.small,
            muted: effect.mechanism == null,
          ),
        ],
      ),
    );
  }
}

class _WithheldSection extends StatelessWidget {
  const _WithheldSection({required this.report});

  final TherapyEffectReport report;

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
    child: ExpansionTile(
      key: const Key('therapy-effects-withheld'),
      tilePadding: EdgeInsets.zero,
      title: T(
        'Also measured, not shown (${report.withheld.length})',
        v: TextVariant.h3,
      ),
      childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
      children: [
        for (final effect in report.withheld)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                T('${metricLabel(effect.metric)} after ${effect.label}'),
                T(
                  therapyWithheldReason(
                    effect.withheld ?? '',
                    report.minSessions,
                  ),
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
