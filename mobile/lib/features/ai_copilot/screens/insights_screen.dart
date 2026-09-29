import 'package:flutter/material.dart';
import '../../../core/widgets/quick_log.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../journal/data/wellness_analytics.dart';
import '../../health/models/health_measurement.dart';
import '../data/longitudinal_insight_service.dart';

class InsightsScreen extends ConsumerStatefulWidget {
  const InsightsScreen({super.key});
  @override
  ConsumerState<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends ConsumerState<InsightsScreen> {
  String _question = 'Weekly summary';
  @override
  Widget build(BuildContext context) {
    final data = ref.watch(wellnessProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Align(alignment: Alignment.centerLeft, child: SincOrb(size: 60)),
        const SizedBox(height: 16),
        Text('Sinc', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 12),
        const Text(
          'A little more understanding, every day. Explore summaries calculated from your saved records.',
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final q in [
              'Weekly summary',
              'My sleep',
              'My heart rate',
              'This month',
              'Long-term patterns',
            ])
              ChoiceChip(
                label: Text(q),
                selected: _question == q,
                onSelected: (_) => setState(() => _question = q),
              ),
          ],
        ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerRight,
          child: Chip(label: Text(_question)),
        ),
        const SizedBox(height: 12),
        data.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, s) => const Text('Unable to read your records.'),
          data: (d) {
            if (_question == 'Long-term patterns') {
              final insights = const LongitudinalInsightService().build(d);
              return Column(
                children: [
                  if (insights.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(22),
                        child: Text(
                          'At least four recorded days in both the recent and previous period are needed for longitudinal insights.',
                        ),
                      ),
                    ),
                  for (final insight in insights)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(_insightIcon(insight.direction)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    insight.title,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                                Text('${(insight.confidence * 100).round()}%'),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(insight.summary),
                            const SizedBox(height: 8),
                            Text(
                              insight.evidence,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${insight.sampleDays} recorded days across both periods',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    'These summaries describe recorded patterns. They do not determine causes or diagnose a condition.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              );
            }
            final now = DateTime.now();
            final a = WellnessAnalytics(
              d,
              now.subtract(Duration(days: _question == 'This month' ? 30 : 7)),
              now,
            );
            final type = _question == 'My sleep'
                ? MeasurementType.sleep
                : MeasurementType.heartRate;
            final avg = a.average(type);
            final answer =
                _question == 'Weekly summary' || _question == 'This month'
                ? a.summary()
                : avg == null
                ? 'No readings recorded for this metric in the last 7 days. Add a measurement or sync your ring.'
                : 'You recorded ${a.readings(type).length} readings in the last 7 days, averaging ${avg.toStringAsFixed(1)} ${a.readings(type).last.unit}. This describes the recorded values only; it does not identify causes or diagnose a condition.';
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: SelectableText(answer),
              ),
            );
          },
        ),
        const SizedBox(height: 24),
        const Text(
          'Open-ended AI chat requires the FastAPI wellness service. No AI provider key is stored in this app.',
        ),
      ],
    );
  }

  IconData _insightIcon(InsightDirection direction) => switch (direction) {
    InsightDirection.improving => Icons.trending_up,
    InsightDirection.declining => Icons.trending_down,
    InsightDirection.stable => Icons.trending_flat,
    InsightDirection.neutral => Icons.insights_outlined,
  };
}
