import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../dashboard/widgets/metric_card.dart';
import '../../journal/providers/wellness_provider.dart';
import '../data/sleep_analysis.dart';

enum SleepView {
  day('Day', 1),
  week('Week', 7),
  month('Month', 30);

  const SleepView(this.label, this.days);
  final String label;
  final int days;
}

class SleepScreen extends ConsumerStatefulWidget {
  const SleepScreen({super.key});
  @override
  ConsumerState<SleepScreen> createState() => _SleepScreenState();
}

class _SleepScreenState extends ConsumerState<SleepScreen> {
  DateTime date = DateTime.now();
  SleepView view = SleepView.week;
  final analysis = const SleepAnalysis();

  @override
  Widget build(BuildContext context) {
    final readings = ref.watch(displayedMeasurementsProvider);
    final data = ref.watch(wellnessProvider).asData?.value;
    final target = data?.goal('sleepGoal', 8) ?? 8;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Sleep', style: theme.textTheme.headlineLarge),
            ),
            IconButton(
              tooltip: 'Health sources',
              onPressed: () => context.push('/health-consent'),
              icon: const Icon(Icons.add_link),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Sleep timing, duration and stages when your data source provides them.',
        ),
        const SizedBox(height: 20),
        SegmentedButton<SleepView>(
          segments: [
            for (final item in SleepView.values)
              ButtonSegment(value: item, label: Text(item.label)),
          ],
          selected: {view},
          onSelectionChanged: (value) => setState(() => view = value.single),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: () =>
                  setState(() => date = date.subtract(const Duration(days: 1))),
              icon: const Icon(Icons.chevron_left),
            ),
            Text(
              DateFormat('EEE, d MMM').format(date),
              style: theme.textTheme.titleMedium,
            ),
            IconButton(
              onPressed: _isToday(date)
                  ? null
                  : () => setState(
                      () => date = date.add(const Duration(days: 1)),
                    ),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 12),
        readings.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) =>
              const _SleepMessage('Sleep records could not be loaded.'),
          data: (values) {
            final summary = analysis.summarize(
              values,
              date,
              targetHours: target,
            );
            if (summary.totalHours <= 0 && summary.timeInBedHours <= 0) {
              return const _SleepMessage('No sleep data for this night.');
            }
            final nightly = [
              for (var offset = view.days - 1; offset >= 0; offset--)
                analysis.summarize(
                  values,
                  date.subtract(Duration(days: offset)),
                  targetHours: target,
                ),
            ];
            return Column(
              children: [
                _SleepHero(summary: summary, target: target),
                if (view != SleepView.day) ...[
                  const SizedBox(height: 12),
                  _SleepTrend(values: nightly, target: target),
                ],
                const SizedBox(height: 12),
                _TimingCard(summary),
                const SizedBox(height: 12),
                _StageCard(summary),
                const SizedBox(height: 12),
                _ScoreCard(summary),
              ],
            );
          },
        ),
      ],
    );
  }

  bool _isToday(DateTime value) {
    final now = DateTime.now();
    return value.year == now.year &&
        value.month == now.month &&
        value.day == now.day;
  }
}

class _SleepHero extends StatelessWidget {
  const _SleepHero({required this.summary, required this.target});
  final SleepSummary summary;
  final double target;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            height: 76,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: (summary.totalHours / target).clamp(0, 1).toDouble(),
                    strokeWidth: 6,
                  ),
                ),
                const Icon(Icons.bedtime_outlined),
              ],
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'TOTAL SLEEP',
                  style: TextStyle(fontSize: 10, letterSpacing: 1.4),
                ),
                const SizedBox(height: 6),
                Text(
                  _hours(summary.totalHours),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                Text(
                  'Goal ${target.toStringAsFixed(target == target.roundToDouble() ? 0 : 1)} h · ${summary.sources.map((e) => e.name).join(', ')}',
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _TimingCard extends StatelessWidget {
  const _TimingCard(this.summary);
  final SleepSummary summary;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Expanded(
            child: _Value(
              'Bedtime',
              summary.bedtime == null
                  ? '—'
                  : DateFormat.jm().format(summary.bedtime!),
            ),
          ),
          Expanded(
            child: _Value(
              'Wake time',
              summary.wakeTime == null
                  ? '—'
                  : DateFormat.jm().format(summary.wakeTime!),
            ),
          ),
          Expanded(
            child: _Value(
              'Efficiency',
              summary.efficiency == null
                  ? '—'
                  : '${summary.efficiency!.round()}%',
            ),
          ),
        ],
      ),
    ),
  );
}

class _StageCard extends StatelessWidget {
  const _StageCard(this.summary);
  final SleepSummary summary;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sleep stages', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          if (summary.stageHours.isEmpty)
            const Text('Stage data is unavailable from this source.')
          else
            for (final stage in summary.stageHours.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(metricLabel(stage.key))),
                        Text(_hours(stage.value)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: summary.timeInBedHours <= 0
                          ? 0
                          : (stage.value / summary.timeInBedHours)
                                .clamp(0, 1)
                                .toDouble(),
                    ),
                  ],
                ),
              ),
        ],
      ),
    ),
  );
}

class _ScoreCard extends StatelessWidget {
  const _ScoreCard(this.summary);
  final SleepSummary summary;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Estimated sleep score · ${summary.score ?? '—'}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          const Text(
            'A wellness estimate from duration and efficiency. It is not a medical assessment.',
          ),
          const SizedBox(height: 14),
          for (final driver in summary.scoreDrivers.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(child: Text(driver.key)),
                  Text('+${driver.value} points'),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

class _SleepTrend extends StatelessWidget {
  const _SleepTrend({required this.values, required this.target});
  final List<SleepSummary> values;
  final double target;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sleep duration', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          SizedBox(
            height: 130,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final value in values)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                heightFactor:
                                    (value.totalHours / (target * 1.25))
                                        .clamp(0, 1)
                                        .toDouble(),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 5),
                          if (values.length <= 7)
                            Text(
                              DateFormat.E().format(value.date).substring(0, 1),
                              style: const TextStyle(fontSize: 10),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _SleepMessage extends StatelessWidget {
  const _SleepMessage(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(26),
      child: Column(
        children: [
          const Icon(Icons.bedtime_outlined, size: 42),
          const SizedBox(height: 14),
          Text(message),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => context.push('/health-consent'),
            child: const Text('Connect a health source'),
          ),
        ],
      ),
    ),
  );
}

class _Value extends StatelessWidget {
  const _Value(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 6),
      FittedBox(
        child: Text(value, style: Theme.of(context).textTheme.titleLarge),
      ),
    ],
  );
}

String _hours(double hours) {
  final minutes = (hours * 60).round();
  return '${minutes ~/ 60}h ${minutes % 60}m';
}
