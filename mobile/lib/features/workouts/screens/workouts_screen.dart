import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/widgets/async_action.dart';
import '../../journal/models/journal_entry.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../journal/screens/entry_editor.dart';
import '../data/workout_analysis.dart';

class WorkoutsScreen extends ConsumerStatefulWidget {
  const WorkoutsScreen({super.key});
  @override
  ConsumerState<WorkoutsScreen> createState() => _WorkoutsScreenState();
}

class _WorkoutsScreenState extends ConsumerState<WorkoutsScreen> {
  DateTime _day = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(wellnessProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Workouts',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
            ),
            IconButton(
              onPressed: () =>
                  setState(() => _day = _day.subtract(const Duration(days: 1))),
              icon: const Icon(Icons.chevron_left),
            ),
            TextButton(
              onPressed: _chooseDay,
              child: Text(DateFormat('d MMM').format(_day)),
            ),
            IconButton(
              onPressed: _isToday
                  ? null
                  : () => setState(
                      () => _day = _day.add(const Duration(days: 1)),
                    ),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 20),
        ...state.when(
          loading: () => [const LinearProgressIndicator()],
          error: (_, _) => [
            TextButton(
              onPressed: () => ref.invalidate(wellnessProvider),
              child: const Text('Unable to load workouts. Retry'),
            ),
          ],
          data: (data) {
            final analysis = WorkoutAnalysis(data, _day);
            final totals = analysis.totals;
            return [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        totals.exerciseCount == 0
                            ? 'Rest or recovery day'
                            : '${totals.exerciseCount} exercises logged',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 24,
                        runSpacing: 16,
                        children: [
                          _Summary('Duration', totals.duration, 'min'),
                          _Summary('Volume', totals.volume, 'kg'),
                          _Summary('Distance', totals.distance, 'km'),
                          _Summary('Energy', totals.calories, 'kcal'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.calendar_view_week_outlined),
                  title: Text('${analysis.sessionsLastSevenDays} active days'),
                  subtitle: const Text('Training frequency in the last 7 days'),
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () => openEntryEditor(context, EntryKind.workout),
                icon: const Icon(Icons.add),
                label: const Text('Log exercise'),
              ),
              const SizedBox(height: 24),
              Text('Session', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              if (analysis.exercises.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(22),
                    child: Text('No exercises logged for this day.'),
                  ),
                ),
              for (final exercise in analysis.exercises)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Icon(
                        exercise.number('distance') > 0
                            ? Icons.directions_run
                            : Icons.fitness_center,
                      ),
                    ),
                    title: Row(
                      children: [
                        Expanded(child: Text(exercise.title)),
                        if (analysis.isPersonalBest(exercise))
                          const Icon(Icons.emoji_events_outlined, size: 19),
                      ],
                    ),
                    subtitle: Text(_details(exercise)),
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) async {
                        if (value == 'edit') {
                          await openEntryEditor(
                            context,
                            EntryKind.workout,
                            entry: exercise,
                          );
                        } else {
                          await runAction(
                            context,
                            () => ref
                                .read(wellnessProvider.notifier)
                                .deleteEntry(exercise.id),
                          );
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ),
                ),
              if (analysis.personalBests.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  'Personal bests',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                Card(
                  child: Column(
                    children: [
                      for (final best in analysis.personalBests.entries.take(8))
                        ListTile(
                          leading: const Icon(Icons.emoji_events_outlined),
                          title: Text(_title(best.key)),
                          trailing: Text('${best.value.toStringAsFixed(1)} kg'),
                        ),
                    ],
                  ),
                ),
              ],
            ];
          },
        ),
      ],
    );
  }

  String _details(JournalEntry entry) {
    final values = <String>[];
    final type = entry.fields['workoutType'];
    if (type?.isNotEmpty == true) values.add(type!);
    if (entry.number('sets') > 0 || entry.number('reps') > 0) {
      values.add(
        '${entry.number('sets').round()} × ${entry.number('reps').round()}',
      );
    }
    if (entry.number('load') > 0) {
      values.add('${entry.number('load').toStringAsFixed(1)} kg');
    }
    if (entry.number('distance') > 0) {
      values.add('${entry.number('distance').toStringAsFixed(1)} km');
    }
    values.add('${entry.number('duration').round()} min');
    if (entry.number('rpe') > 0) {
      values.add('RPE ${entry.number('rpe').round()}');
    }
    return values.join(' · ');
  }

  String _title(String value) => value
      .split(' ')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');

  bool get _isToday {
    final now = DateTime.now();
    return _day.year == now.year &&
        _day.month == now.month &&
        _day.day == now.day;
  }

  Future<void> _chooseDay() async {
    final value = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (value != null) setState(() => _day = value);
  }
}

class _Summary extends StatelessWidget {
  const _Summary(this.label, this.value, this.unit);
  final String label, unit;
  final double value;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 110,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(
          '${value.round()} $unit',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    ),
  );
}
