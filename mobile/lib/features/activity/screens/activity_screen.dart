import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../health/screens/measurement_editor.dart';
import '../../journal/models/journal_entry.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../journal/screens/entry_editor.dart';
import '../data/activity_analysis.dart';

enum ActivityRange {
  week('Week', 7),
  month('Month', 30);

  const ActivityRange(this.label, this.days);
  final String label;
  final int days;
}

class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});
  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  DateTime date = DateTime.now();
  ActivityRange range = ActivityRange.week;
  final analysis = const ActivityAnalysis();

  @override
  Widget build(BuildContext context) {
    final readings = ref.watch(displayedMeasurementsProvider);
    final wellness = ref.watch(wellnessProvider).asData?.value;
    final stepsGoal = wellness?.goal('stepsGoal', 10000) ?? 10000;
    final activeGoal = wellness?.goal('activityGoal', 30) ?? 30;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Text('Activity', style: theme.textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text('Movement from connected sources and records you add.'),
        const SizedBox(height: 18),
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
              onPressed: _isToday
                  ? null
                  : () => setState(
                      () => date = date.add(const Duration(days: 1)),
                    ),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 14),
        readings.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Activity data could not be loaded.'),
            ),
          ),
          data: (values) {
            final today = analysis.summarize(values, date);
            final history = [
              for (var offset = range.days - 1; offset >= 0; offset--)
                analysis.summarize(
                  values,
                  date.subtract(Duration(days: offset)),
                ),
            ];
            return Column(
              children: [
                _GoalCard(
                  today: today,
                  stepsGoal: stepsGoal,
                  activeGoal: activeGoal,
                ),
                const SizedBox(height: 12),
                _MetricsGrid(today),
                const SizedBox(height: 18),
                SegmentedButton<ActivityRange>(
                  segments: [
                    for (final value in ActivityRange.values)
                      ButtonSegment(value: value, label: Text(value.label)),
                  ],
                  selected: {range},
                  onSelectionChanged: (value) =>
                      setState(() => range = value.single),
                ),
                const SizedBox(height: 12),
                _ActivityBars(history: history, goal: stepsGoal),
                const SizedBox(height: 12),
                _History(history),
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => openEntryEditor(context, EntryKind.workout),
              icon: const Icon(Icons.fitness_center),
              label: const Text('Log workout'),
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const MeasurementEditor(),
                ),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Add activity data'),
            ),
          ],
        ),
      ],
    );
  }

  bool get _isToday {
    final now = DateTime.now();
    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({
    required this.today,
    required this.stepsGoal,
    required this.activeGoal,
  });
  final DailyActivity today;
  final double stepsGoal;
  final double activeGoal;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.directions_walk, size: 36),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  '${today.steps.round()} steps',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LinearProgressIndicator(value: (today.steps / stepsGoal).clamp(0, 1)),
          const SizedBox(height: 6),
          Text(
            '${(today.steps / stepsGoal * 100).clamp(0, 999).round()}% of ${stepsGoal.round()} daily goal',
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: (today.activeMinutes / activeGoal).clamp(0, 1),
          ),
          const SizedBox(height: 6),
          Text(
            '${today.activeMinutes.round()} of ${activeGoal.round()} active minutes',
          ),
        ],
      ),
    ),
  );
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid(this.value);
  final DailyActivity value;
  @override
  Widget build(BuildContext context) => GridView.count(
    crossAxisCount: 2,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    mainAxisSpacing: 10,
    crossAxisSpacing: 10,
    childAspectRatio: 1.65,
    children: [
      _Metric('Distance', '${value.distanceKm.toStringAsFixed(1)} km'),
      _Metric('Active energy', '${value.activeCalories.round()} kcal'),
      _Metric('Active time', '${value.activeMinutes.round()} min'),
      _Metric(
        'Sedentary time',
        value.sedentaryMinutes > 0
            ? '${value.sedentaryMinutes.round()} min'
            : 'Unavailable',
      ),
    ],
  );
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          FittedBox(
            child: Text(value, style: Theme.of(context).textTheme.titleLarge),
          ),
        ],
      ),
    ),
  );
}

class _ActivityBars extends StatelessWidget {
  const _ActivityBars({required this.history, required this.goal});
  final List<DailyActivity> history;
  final double goal;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Steps history', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          SizedBox(
            height: 130,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final day in history)
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
                                heightFactor: (day.steps / (goal * 1.25)).clamp(
                                  0,
                                  1,
                                ),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (history.length <= 7)
                            Text(
                              DateFormat.E().format(day.date).substring(0, 1),
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

class _History extends StatelessWidget {
  const _History(this.history);
  final List<DailyActivity> history;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          for (final day in history.reversed.take(7))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(DateFormat.MMMd().format(day.date)),
              subtitle: Text(
                day.sources.isEmpty
                    ? 'No connected activity data'
                    : day.sources.map((source) => source.name).join(', '),
              ),
              trailing: Text('${day.steps.round()} steps'),
            ),
        ],
      ),
    ),
  );
}
