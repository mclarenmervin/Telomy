import '../../journal/models/journal_entry.dart';
import '../../journal/models/wellness_data.dart';

class WorkoutTotals {
  const WorkoutTotals({
    this.duration = 0,
    this.volume = 0,
    this.distance = 0,
    this.calories = 0,
    this.exerciseCount = 0,
  });
  final double duration, volume, distance, calories;
  final int exerciseCount;
}

class WorkoutAnalysis {
  WorkoutAnalysis(this.data, this.day);
  final WellnessData data;
  final DateTime day;

  List<JournalEntry> get all =>
      data.entries.where((entry) => entry.kind == EntryKind.workout).toList()
        ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));

  List<JournalEntry> get exercises => all
      .where(
        (entry) =>
            entry.recordedAt.year == day.year &&
            entry.recordedAt.month == day.month &&
            entry.recordedAt.day == day.day,
      )
      .toList();

  WorkoutTotals get totals => WorkoutTotals(
    duration: exercises.fold(0, (sum, e) => sum + e.number('duration')),
    volume: exercises.fold(
      0,
      (sum, e) => sum + e.number('sets') * e.number('reps') * e.number('load'),
    ),
    distance: exercises.fold(0, (sum, e) => sum + e.number('distance')),
    calories: exercises.fold(0, (sum, e) => sum + e.number('calories')),
    exerciseCount: exercises.length,
  );

  Map<String, double> get personalBests {
    final bests = <String, double>{};
    for (final entry in all) {
      final load = entry.number('load');
      if (load <= 0) continue;
      final key = entry.title.trim().toLowerCase();
      if (load > (bests[key] ?? 0)) bests[key] = load;
    }
    return bests;
  }

  bool isPersonalBest(JournalEntry entry) {
    final load = entry.number('load');
    return load > 0 && personalBests[entry.title.trim().toLowerCase()] == load;
  }

  int get sessionsLastSevenDays {
    final now = DateTime.now();
    final cutoff = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(const Duration(days: 6));
    return {
      for (final entry in all)
        if (!entry.recordedAt.isBefore(cutoff) &&
            !entry.recordedAt.isAfter(now))
          '${entry.recordedAt.year}-${entry.recordedAt.month}-${entry.recordedAt.day}',
    }.length;
  }
}
