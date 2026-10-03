import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/activity_report.dart';
import '../providers/activity_report_provider.dart';

/// Shows the agent's analysis of a finished session.
///
/// Deliberately never blocks the user: while the backend works this is a quiet
/// line, not a spinner over the screen, so they can carry on elsewhere.
class ActivityReportCard extends ConsumerWidget {
  const ActivityReportCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(activityReportProvider);
    final theme = Theme.of(context);

    if (state.waiting) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'Session saved. Your analysis is being prepared — you can keep '
                  'using the app and it will appear here.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (state.timedOut) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Text(
            'Your session was saved, but the analysis is taking longer than '
            'usual. It will show up here once it is ready.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }

    final report = state.report;
    if (report == null) return const SizedBox.shrink();
    return ReportBody(report: report);
  }
}

class ReportBody extends ConsumerWidget {
  const ReportBody({super.key, required this.report});

  final ActivityReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    report.eventType.isEmpty
                        ? 'Your analysis'
                        : 'Your ${report.eventType} analysis',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () => ref.read(activityReportProvider.notifier).dismiss(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(report.headline, style: theme.textTheme.titleLarge),
            if (report.score != null) ...[
              const SizedBox(height: 14),
              _ScoreRow(score: report.score!),
            ],
            if (report.metrics.isNotEmpty) ...[
              const SizedBox(height: 16),
              _MetricRows(metrics: report.metrics),
            ],
            if (report.escalation.isProminent) ...[
              const SizedBox(height: 14),
              _EscalationBlock(
                  escalation: report.escalation, severity: report.severity),
            ],
            for (final section in report.sections) ...[
              const SizedBox(height: 18),
              Text(
                section.title,
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(section.body, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 18),
            Text(
              _footnote(report),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            if (!report.escalation.isProminent)
              _EscalationBlock(
                  escalation: report.escalation, severity: report.severity),
          ],
        ),
      ),
    );
  }

  String _footnote(ActivityReport report) {
    final parts = <String>[];
    if (report.sessionsCompared > 0) {
      parts.add('compared with ${report.sessionsCompared} past sessions');
    } else {
      parts.add('no comparable history yet');
    }
    if (report.dataQuality != 'full') {
      parts.add('sensor data: ${report.dataQuality}');
    }
    if (report.narrationIncomplete) {
      parts.add('summary generated offline');
    }
    return parts.join(' · ');
  }
}

class _ScoreRow extends StatelessWidget {
  const _ScoreRow({required this.score});

  final ReportScore score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '${score.value}',
          style: theme.textTheme.displaySmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 2),
          child: Text('/${score.scale}', style: theme.textTheme.titleMedium),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (score.label.isNotEmpty)
                  Text(score.label, style: theme.textTheme.titleSmall),
                if (score.basis.isNotEmpty)
                  Text(score.basis, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Amber for attention, the error colour for urgent. The scheme has no warning
/// colour, so it is defined here alongside its only consumer.
const _attentionLight = Color(0xFFB26A00);
const _attentionDark = Color(0xFFFFB74D);

Color severityColor(BuildContext context, String severity) {
  final theme = Theme.of(context);
  switch (severity) {
    case 'urgent':
      return theme.colorScheme.error;
    case 'attention':
      return theme.brightness == Brightness.dark ? _attentionDark : _attentionLight;
    default:
      return theme.colorScheme.onSurfaceVariant;
  }
}

class _MetricRows extends StatelessWidget {
  const _MetricRows({required this.metrics});

  final List<ReportMetric> metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final metric in metrics)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(metric.label,
                          style: theme.textTheme.bodyMedium,
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_trim(metric.value)}${metric.unit}',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (metric.delta != null && metric.delta != 0) ...[
                      const SizedBox(width: 6),
                      // The arrow follows the delta's sign; the colour says whether
                      // that direction is good. Lower is better for heart rate,
                      // higher for blood oxygen, so the two must not be conflated.
                      Icon(
                        metric.delta! > 0
                            ? Icons.trending_up_rounded
                            : Icons.trending_down_rounded,
                        size: 14,
                        color: metric.direction == 'better'
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                      ),
                      Text(_trim(metric.delta!.abs()),
                          style: theme.textTheme.bodySmall),
                    ],

                  ],
                ),
                if (metric.severity != 'normal') ...[
                  const SizedBox(height: 3),
                  // Its own row: on the value line this was the child that got clipped
                  // at ordinary phone widths, and it is the signal that must not be.
                  Row(
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          size: 15, color: severityColor(context, metric.severity)),
                      const SizedBox(width: 4),
                      Text(
                        metric.severity,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: severityColor(context, metric.severity)),
                      ),
                    ],
                  ),
                ],
                if (metric.note.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(metric.note,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor)),
                ],
              ],
            ),
          ),
      ],
    );
  }

  String _trim(num value) => value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1);
}


class _EscalationBlock extends StatelessWidget {
  const _EscalationBlock({required this.escalation, required this.severity});

  final ReportEscalation escalation;
  final String severity;

  void _book(BuildContext context) => context.push('/consultations');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!escalation.isProminent) {
      // Easy to ignore, which is correct on an ordinary day.
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () => _book(context),
          child: Text(escalation.title),
        ),
      );
    }
    final color = severityColor(context, severity == 'normal' ? 'attention' : severity);
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  escalation.title,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: color, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (escalation.body.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(escalation.body, style: theme.textTheme.bodyMedium),
          ],
          const SizedBox(height: 10),
          FilledButton(
            onPressed: () => _book(context),
            child: const Text('Book a consultation'),
          ),
        ],
      ),
    );
  }
}
