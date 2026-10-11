import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
class TherapyEffectsSection extends ConsumerWidget {
  const TherapyEffectsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final report = ref.watch(therapyEffectsProvider);

    return Column(
      key: const Key('therapy-effects'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('What your sessions do', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Measured in the hour after each session against the hour before, '
          'across all the sessions you have logged.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        ...report.when(
          loading: () => [const LinearProgressIndicator()],
          error: (error, _) => [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                  error is TherapyEffectsUnavailable
                      ? error.message
                      : 'This could not be worked out just now.',
                ),
              ),
            ),
          ],
          data: (data) => _results(context, data),
        ),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
      ],
    );
  }

  List<Widget> _results(BuildContext context, TherapyEffectReport report) {
    final theme = Theme.of(context);
    return [
      if (report.tested == 0 && report.withheld.isEmpty)
        Card(
          key: const Key('therapy-effects-none'),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Text(
              'Once you have logged a few sauna or cold plunge sessions with '
              'your ring on, we will measure what they do to you. It takes '
              '${report.minSessions} before a run means anything.',
            ),
          ),
        ),
      for (final effect in report.reported)
        Card(
          key: Key('therapy-effect-${effect.modality}-${effect.metric}'),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${metricLabel(effect.metric)} after ${effect.label}',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Icon(
                      effect.rose ? Icons.north_rounded : Icons.south_rounded,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${effect.meanDelta!.abs().toStringAsFixed(1)} '
                      '${metricUnit(effect.metric)} '
                      '${effect.rose ? 'higher' : 'lower'}',
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Across ${effect.sessions} '
                  '${effect.sessions == 1 ? 'session' : 'sessions'}'
                  '${effect.sessionsConfounded > 0 ? ' — ${effect.sessionsConfounded} more were left out because something else you logged overlapped them' : ''}.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  effect.mechanism ??
                      'Nobody has reviewed why this happens, so we are not '
                          'going to guess at it.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: effect.mechanism == null
                        ? theme.colorScheme.outline
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      if (report.withheld.isNotEmpty)
        Card(
          child: ExpansionTile(
            key: const Key('therapy-effects-withheld'),
            title: Text(
              'Also measured, not shown (${report.withheld.length})',
              style: theme.textTheme.titleSmall,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
            children: [
              for (final effect in report.withheld)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${metricLabel(effect.metric)} after ${effect.label}',
                        style: theme.textTheme.bodyMedium,
                      ),
                      Text(
                        therapyWithheldReason(
                            effect.withheld ?? '', report.minSessions),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      if (report.reported.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(
          'This is what happens in the hour afterwards. It does not say '
          'whether the therapy is doing you good over months — for several of '
          'these signals the long-term effect runs the other way, and we '
          'cannot measure that yet.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    ];
  }
}
