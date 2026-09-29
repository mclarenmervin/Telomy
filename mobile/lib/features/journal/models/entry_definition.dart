import 'journal_entry.dart';

class EntryField {
  const EntryField(
    this.key,
    this.label, {
    this.numeric = false,
    this.max = 100000,
    this.required = false,
  });
  final String key, label;
  final bool numeric, required;
  final double max;
}

class EntryDefinition {
  const EntryDefinition(this.title, this.hint, this.fields);
  final String title, hint;
  final List<EntryField> fields;
  static EntryDefinition forKind(EntryKind kind) => switch (kind) {
    EntryKind.event => const EntryDefinition(
      'Timeline',
      'Record a health, activity, diet, stress, medical, or life event.',
      [
        EntryField('category', 'Category'),
        EntryField('duration', 'Duration (minutes)', numeric: true, max: 10080),
      ],
    ),
    EntryKind.therapy => const EntryDefinition(
      'Therapies',
      'Track a session and your own observations.',
      [
        EntryField('type', 'Therapy type'),
        EntryField('duration', 'Duration (minutes)', numeric: true, max: 1440),
        EntryField('result', 'Result / how you felt'),
      ],
    ),
    EntryKind.meal => const EntryDefinition(
      'Nutrition',
      'Log food from its label or your measured recipe. Totals use your entries.',
      [
        EntryField('mealType', 'Meal type'),
        EntryField('portion', 'Portion / serving'),
        EntryField(
          'calories',
          'Energy (kcal)',
          numeric: true,
          required: true,
          max: 20000,
        ),
        EntryField('protein', 'Protein (g)', numeric: true, max: 2000),
        EntryField('carbs', 'Carbohydrate (g)', numeric: true, max: 3000),
        EntryField('fat', 'Fat (g)', numeric: true, max: 2000),
        EntryField('fiber', 'Fibre (g)', numeric: true, max: 500),
        EntryField('sugar', 'Sugar (g)', numeric: true, max: 1000),
        EntryField('sodium', 'Sodium (mg)', numeric: true, max: 50000),
      ],
    ),
    EntryKind.workout => const EntryDefinition(
      'Workouts',
      'Record an exercise or session. Add separate entries for each exercise.',
      [
        EntryField('workoutType', 'Workout type'),
        EntryField('muscleGroup', 'Muscle group'),
        EntryField(
          'duration',
          'Duration (minutes)',
          numeric: true,
          required: true,
          max: 1440,
        ),
        EntryField('sets', 'Sets', numeric: true, max: 100),
        EntryField('reps', 'Repetitions per set', numeric: true, max: 1000),
        EntryField('load', 'Load (kg)', numeric: true, max: 1000),
        EntryField('distance', 'Distance (km)', numeric: true, max: 1000),
        EntryField('rpe', 'Effort / RPE (1–10)', numeric: true, max: 10),
        EntryField(
          'calories',
          'Active energy (kcal)',
          numeric: true,
          max: 10000,
        ),
      ],
    ),
    EntryKind.water => const EntryDefinition(
      'Hydration',
      'Record each drink to track your daily total.',
      [
        EntryField(
          'amount',
          'Water (ml)',
          numeric: true,
          required: true,
          max: 10000,
        ),
      ],
    ),
    EntryKind.environment => const EntryDefinition(
      'Environment',
      'Record an exposure with the location category and observed conditions.',
      [
        EntryField('location', 'Location category'),
        EntryField('temperature', 'Air temperature (°C)'),
        EntryField('humidity', 'Humidity (%)', numeric: true, max: 100),
        EntryField('aqi', 'AQI', numeric: true, max: 1000),
        EntryField('uv', 'UV index', numeric: true, max: 30),
      ],
    ),
    EntryKind.genetics => const EntryDefinition(
      'Genetics records',
      'Keep sample and laboratory report metadata. No diagnoses or risk predictions are generated.',
      [
        EntryField('lab', 'Laboratory'),
        EntryField('sample', 'Sample / report reference'),
        EntryField('trait', 'Trait or marker as reported'),
        EntryField('ancestry', 'Ancestry metadata (optional)'),
      ],
    ),
    EntryKind.plan => const EntryDefinition(
      'My plans',
      'Create your own workout, meal, or habit plan, then log completed sessions.',
      [
        EntryField('type', 'Plan type'),
        EntryField('schedule', 'Schedule'),
        EntryField('target', 'Personal target'),
      ],
    ),
    EntryKind.checkIn => const EntryDefinition(
      'Progress check-ins',
      'Record energy, adherence, and how your week felt.',
      [
        EntryField('energy', 'Energy (1–10)', numeric: true, max: 10),
        EntryField('mood', 'Mood'),
        EntryField(
          'waist',
          'Waist circumference (cm)',
          numeric: true,
          max: 300,
        ),
        EntryField('bodyFat', 'Body fat (%)', numeric: true, max: 100),
      ],
    ),
    EntryKind.lab => const EntryDefinition(
      'Lab results',
      'Enter values exactly as shown on your laboratory report.',
      [
        EntryField('category', 'Category'),
        EntryField('value', 'Result value', numeric: true, required: true),
        EntryField('unit', 'Unit', required: true),
        EntryField('rangeLow', 'Reference range low', numeric: true),
        EntryField('rangeHigh', 'Reference range high', numeric: true),
        EntryField('laboratory', 'Laboratory'),
        EntryField('reportId', 'Report reference'),
      ],
    ),
    EntryKind.medication => const EntryDefinition(
      'Medications',
      'Record a medication using the instructions provided by your prescriber.',
      [
        EntryField('dose', 'Dose', required: true),
        EntryField('frequency', 'Frequency', required: true),
        EntryField('time', 'Reminder time (HH:MM)'),
        EntryField('startDate', 'Start date (YYYY-MM-DD)'),
        EntryField('endDate', 'End date (YYYY-MM-DD)'),
        EntryField('prescriber', 'Prescriber'),
        EntryField('reason', 'Reason / label'),
      ],
    ),
    EntryKind.medicationDose => const EntryDefinition(
      'Medication dose',
      'Record a taken medication dose.',
      [EntryField('dose', 'Dose'), EntryField('medicationId', 'Medication ID')],
    ),
    EntryKind.consultation => const EntryDefinition(
      'Consultations',
      'Record a scheduled consultation and its details.',
      [
        EntryField('provider', 'Provider', required: true),
        EntryField('serviceId', 'Service ID'),
        EntryField('duration', 'Duration (minutes)', numeric: true, max: 480),
        EntryField('price', 'Price', numeric: true, max: 1000000),
        EntryField('delivery', 'Meeting type'),
        EntryField('status', 'Status'),
      ],
    ),
    EntryKind.communityPost => const EntryDefinition(
      'Community post',
      'Share a wellness experience with the community.',
      [
        EntryField('topic', 'Topic'),
        EntryField('likes', 'Likes', numeric: true),
      ],
    ),
    EntryKind.communityReply => const EntryDefinition(
      'Community reply',
      'Reply to a community post.',
      [EntryField('postId', 'Post ID')],
    ),
  };
}
