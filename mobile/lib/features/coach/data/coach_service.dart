import '../../health/models/health_measurement.dart';
import '../../journal/models/journal_entry.dart';
import '../../journal/models/wellness_data.dart';

class CoachAction {
  const CoachAction({
    required this.id,
    required this.title,
    required this.detail,
    required this.category,
    required this.progress,
    required this.target,
    required this.unit,
    required this.priority,
  });
  final String id, title, detail, category, unit;
  final double progress, target, priority;
  double get completion => target <= 0 ? 0 : (progress / target).clamp(0, 1);
}

class CoachService {
  const CoachService();

  List<CoachAction> actions(WellnessData data, DateTime date) {
    final start = DateTime(date.year, date.month, date.day);
    final end = start.add(const Duration(days: 1));
    final actions = <CoachAction>[];
    final steps = _measurementTotal(data, MeasurementType.steps, start, end);
    final stepGoal = data.goal('stepsGoal', 8000);
    if (steps < stepGoal) {
      actions.add(
        CoachAction(
          id: 'steps-${_key(start)}',
          title: 'Add a walk',
          detail:
              '${(stepGoal - steps).round()} steps remain toward today’s goal.',
          category: 'Movement',
          progress: steps,
          target: stepGoal,
          unit: 'steps',
          priority: 1 - steps / stepGoal,
        ),
      );
    }
    final water = _entryTotal(data, EntryKind.water, 'amount', start, end);
    final waterGoal = data.goal('waterGoal', 2500);
    if (water < waterGoal) {
      actions.add(
        CoachAction(
          id: 'water-${_key(start)}',
          title: 'Continue hydrating',
          detail:
              '${(waterGoal - water).round()} ml remains toward your logged-water goal.',
          category: 'Hydration',
          progress: water,
          target: waterGoal,
          unit: 'ml',
          priority: .8 * (1 - water / waterGoal),
        ),
      );
    }
    final protein = _entryTotal(data, EntryKind.meal, 'protein', start, end);
    final proteinGoal = data.goal('proteinGoal', 100);
    if (protein < proteinGoal) {
      actions.add(
        CoachAction(
          id: 'protein-${_key(start)}',
          title: 'Plan your next meal',
          detail:
              '${(proteinGoal - protein).round()} g protein remains based on your goal.',
          category: 'Nutrition',
          progress: protein,
          target: proteinGoal,
          unit: 'g',
          priority: .65 * (1 - protein / proteinGoal),
        ),
      );
    }
    final activeMinutes =
        _measurementTotal(data, MeasurementType.activity, start, end) +
        _entryTotal(data, EntryKind.workout, 'duration', start, end);
    final activityGoal = data.goal('activityGoal', 30);
    if (activeMinutes < activityGoal) {
      actions.add(
        CoachAction(
          id: 'activity-${_key(start)}',
          title: 'Complete a short activity block',
          detail:
              '${(activityGoal - activeMinutes).round()} active minutes remain.',
          category: 'Training',
          progress: activeMinutes,
          target: activityGoal,
          unit: 'min',
          priority: .9 * (1 - activeMinutes / activityGoal),
        ),
      );
    }
    final sleep = _measurementTotal(data, MeasurementType.sleep, start, end);
    final sleepGoal = data.goal('sleepGoal', 8);
    if (sleep > 0 && sleep < sleepGoal) {
      actions.add(
        CoachAction(
          id: 'sleep-${_key(start)}',
          title: 'Protect tonight’s sleep window',
          detail: 'Last recorded sleep was ${sleep.toStringAsFixed(1)} hours.',
          category: 'Recovery',
          progress: sleep,
          target: sleepGoal,
          unit: 'h',
          priority: .95 * (1 - sleep / sleepGoal),
        ),
      );
    }
    actions.sort((a, b) => b.priority.compareTo(a.priority));
    return actions;
  }

  bool saved(WellnessData data, CoachAction action) => data.entries.any(
    (entry) =>
        entry.kind == EntryKind.plan && entry.fields['coachId'] == action.id,
  );

  JournalEntry planFor(CoachAction action) => JournalEntry.create(
    kind: EntryKind.plan,
    title: action.title,
    recordedAt: DateTime.now(),
    notes: action.detail,
    fields: {
      'type': action.category,
      'schedule': 'Today',
      'target': '${action.target.round()} ${action.unit}',
      'coachId': action.id,
    },
  );

  double _measurementTotal(
    WellnessData data,
    MeasurementType type,
    DateTime start,
    DateTime end,
  ) => data.measurements
      .where(
        (item) =>
            item.measurementType == type &&
            !item.recordedAt.isBefore(start) &&
            item.recordedAt.isBefore(end),
      )
      .fold(0, (sum, item) => sum + item.value);

  double _entryTotal(
    WellnessData data,
    EntryKind kind,
    String field,
    DateTime start,
    DateTime end,
  ) => data.entries
      .where(
        (item) =>
            item.kind == kind &&
            !item.recordedAt.isBefore(start) &&
            item.recordedAt.isBefore(end),
      )
      .fold(0, (sum, item) => sum + item.number(field));

  String _key(DateTime value) => '${value.year}-${value.month}-${value.day}';
}
