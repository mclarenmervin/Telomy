import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/widgets/async_action.dart';
import '../../journal/models/journal_entry.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../journal/screens/entry_editor.dart';
import '../data/nutrition_analysis.dart';

class NutritionScreen extends ConsumerStatefulWidget {
  const NutritionScreen({super.key});
  @override
  ConsumerState<NutritionScreen> createState() => _NutritionScreenState();
}

class _NutritionScreenState extends ConsumerState<NutritionScreen> {
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
                'Nutrition',
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
              child: const Text('Unable to load nutrition. Retry'),
            ),
          ],
          data: (data) {
            final analysis = NutritionAnalysis(data, _day);
            final totals = analysis.totals;
            final calorieGoal = analysis.goal('calorieGoal', 2000);
            final proteinGoal = analysis.goal('proteinGoal', 100);
            final carbGoal = analysis.goal('carbGoal', 250);
            final fatGoal = analysis.goal('fatGoal', 67);
            return [
              _EnergyCard(total: totals.calories, goal: calorieGoal),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _MacroCard(
                      label: 'Protein',
                      value: totals.protein,
                      goal: proteinGoal,
                      color: const Color(0xFF337E6B),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MacroCard(
                      label: 'Carbs',
                      value: totals.carbs,
                      goal: carbGoal,
                      color: const Color(0xFFD2973C),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MacroCard(
                      label: 'Fat',
                      value: totals.fat,
                      goal: fatGoal,
                      color: const Color(0xFF9D6B86),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Wrap(
                    spacing: 24,
                    runSpacing: 12,
                    children: [
                      _Nutrient('Fibre', totals.fiber, 'g'),
                      _Nutrient('Sugar', totals.sugar, 'g'),
                      _Nutrient('Sodium', totals.sodium, 'mg'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: () => openEntryEditor(context, EntryKind.meal),
                icon: const Icon(Icons.add),
                label: const Text('Log food'),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Meals',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  Text('${analysis.meals.length} entries'),
                ],
              ),
              const SizedBox(height: 10),
              if (analysis.meals.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(22),
                    child: Text('No food logged for this day.'),
                  ),
                ),
              for (final group in analysis.mealGroups.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 14, bottom: 6),
                  child: Text(
                    group.key,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                for (final meal in group.value)
                  Card(
                    child: ListTile(
                      title: Text(meal.title),
                      subtitle: Text(
                        '${meal.number('calories').round()} kcal · '
                        'P ${meal.number('protein').round()} · '
                        'C ${meal.number('carbs').round()} · '
                        'F ${meal.number('fat').round()}',
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) async {
                          if (value == 'edit') {
                            await openEntryEditor(
                              context,
                              EntryKind.meal,
                              entry: meal,
                            );
                          } else {
                            await runAction(
                              context,
                              () => ref
                                  .read(wellnessProvider.notifier)
                                  .deleteEntry(meal.id),
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
              ],
            ];
          },
        ),
      ],
    );
  }

  bool get _isToday {
    final now = DateTime.now();
    return _day.year == now.year &&
        _day.month == now.month &&
        _day.day == now.day;
  }

  Future<void> _chooseDay() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (selected != null) setState(() => _day = selected);
  }
}

class _EnergyCard extends StatelessWidget {
  const _EnergyCard({required this.total, required this.goal});
  final double total, goal;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          SizedBox(
            width: 88,
            height: 88,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: goal <= 0 ? 0 : (total / goal).clamp(0, 1),
                    strokeWidth: 8,
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                  ),
                ),
                Text('${total.round()}'),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Energy', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text('${(goal - total).clamp(0, goal).round()} kcal remaining'),
                Text('${goal.round()} kcal daily goal'),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _MacroCard extends StatelessWidget {
  const _MacroCard({
    required this.label,
    required this.value,
    required this.goal,
    required this.color,
  });
  final String label;
  final double value, goal;
  final Color color;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: goal <= 0 ? 0 : (value / goal).clamp(0, 1),
            color: color,
          ),
          const SizedBox(height: 8),
          Text('${value.round()} / ${goal.round()} g'),
        ],
      ),
    ),
  );
}

class _Nutrient extends StatelessWidget {
  const _Nutrient(this.label, this.value, this.unit);
  final String label, unit;
  final double value;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 90,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        Text(
          '${value.round()} $unit',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    ),
  );
}
