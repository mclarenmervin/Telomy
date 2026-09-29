import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../journal/models/journal_entry.dart';
import '../../journal/data/wellness_analytics.dart';
import '../../journal/screens/entry_editor.dart';

class FitnessScreen extends ConsumerWidget {
  const FitnessScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(wellnessProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Train. Fuel. Grow.',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 12),
        const Text('Collect the daily details that make progress visible.'),
        const SizedBox(height: 24),
        ...data.when(
          loading: () => [const LinearProgressIndicator()],
          error: (_, s) => [const Text('Unable to load your records.')],
          data: (d) {
            final now = DateTime.now();
            final a = WellnessAnalytics(
              d,
              DateTime(now.year, now.month, now.day),
              now,
            );
            return [
              for (final item in [
                (
                  'Nutrition',
                  '${a.total(EntryKind.meal, 'calories').round()} kcal · ${a.total(EntryKind.meal, 'protein').round()} g protein',
                  '/nutrition',
                  EntryKind.meal,
                  Icons.restaurant_outlined,
                ),
                (
                  'Workouts',
                  '${a.total(EntryKind.workout, 'duration').round()} minutes today',
                  '/workouts',
                  EntryKind.workout,
                  Icons.fitness_center,
                ),
                (
                  'Hydration',
                  '${a.total(EntryKind.water, 'amount').round()} ml today',
                  '/hydration',
                  EntryKind.water,
                  Icons.water_drop_outlined,
                ),
                (
                  'My plans',
                  'Personal meal, training & habit plans',
                  '/plans',
                  EntryKind.plan,
                  Icons.calendar_month,
                ),
                (
                  'Progress check-ins',
                  'Energy, mood, waist and body composition',
                  '/check-ins',
                  EntryKind.checkIn,
                  Icons.insights_outlined,
                ),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            item.$5,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            item.$1,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(item.$2),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 12,
                            children: [
                              FilledButton.tonal(
                                onPressed: () =>
                                    openEntryEditor(context, item.$4),
                                child: const Text('Add entry'),
                              ),
                              TextButton(
                                onPressed: () => context.push(item.$3),
                                child: const Text('View history'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ];
          },
        ),
      ],
    );
  }
}
