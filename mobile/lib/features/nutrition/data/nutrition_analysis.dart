import '../../journal/models/journal_entry.dart';
import '../../journal/models/wellness_data.dart';

class NutritionTotals {
  const NutritionTotals({
    this.calories = 0,
    this.protein = 0,
    this.carbs = 0,
    this.fat = 0,
    this.fiber = 0,
    this.sugar = 0,
    this.sodium = 0,
  });
  final double calories, protein, carbs, fat, fiber, sugar, sodium;
}

class NutritionAnalysis {
  NutritionAnalysis(this.data, this.day);
  final WellnessData data;
  final DateTime day;

  List<JournalEntry> get meals =>
      data.entries
          .where(
            (entry) =>
                entry.kind == EntryKind.meal &&
                entry.recordedAt.year == day.year &&
                entry.recordedAt.month == day.month &&
                entry.recordedAt.day == day.day,
          )
          .toList()
        ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));

  NutritionTotals get totals => NutritionTotals(
    calories: _total('calories'),
    protein: _total('protein'),
    carbs: _total('carbs'),
    fat: _total('fat'),
    fiber: _total('fiber'),
    sugar: _total('sugar'),
    sodium: _total('sodium'),
  );

  double _total(String field) =>
      meals.fold(0, (sum, meal) => sum + meal.number(field));

  double goal(String key, double fallback) => data.goal(key, fallback);

  Map<String, List<JournalEntry>> get mealGroups {
    final result = <String, List<JournalEntry>>{};
    for (final meal in meals) {
      final entered = meal.fields['mealType']?.trim();
      final type = entered?.isNotEmpty == true
          ? entered!
          : meal.recordedAt.hour < 11
          ? 'Breakfast'
          : meal.recordedAt.hour < 16
          ? 'Lunch'
          : 'Dinner';
      result.putIfAbsent(type, () => []).add(meal);
    }
    return result;
  }
}
