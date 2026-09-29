import 'package:flutter/material.dart';
import '../../features/journal/models/journal_entry.dart';
import '../../features/journal/screens/entry_editor.dart';
import '../../features/health/screens/measurement_editor.dart';

Future<void> showQuickLog(BuildContext context) async {
  final kind = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Log something',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              const Text('Small details. A clearer picture of you.'),
              const SizedBox(height: 20),
              for (final item in const {
                'meal': 'Meal & nutrition',
                'water': 'Water',
                'workout': 'Workout',
                'checkIn': 'How you feel',
                'reading': 'Health reading',
                'event': 'Life event',
                'therapy': 'Therapy',
                'lab': 'Lab result',
                'medication': 'Medication',
              }.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(item.value),
                  trailing: const Icon(Icons.add_circle_outline),
                  onTap: () => Navigator.pop(context, item.key),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  if (kind == null || !context.mounted) return;
  if (kind == 'reading') {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const MeasurementEditor()),
    );
  } else {
    await openEntryEditor(context, EntryKind.values.byName(kind));
  }
}

class SincOrb extends StatelessWidget {
  const SincOrb({super.key, this.size = 36});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        center: Alignment.topLeft,
        radius: 1.3,
        colors: [Color(0xFF7BD1BB), Color(0xFF2E8B76), Color(0xFF1F5C4E)],
      ),
    ),
    child: Icon(
      Icons.auto_awesome_outlined,
      color: Colors.white,
      size: size * .5,
    ),
  );
}
