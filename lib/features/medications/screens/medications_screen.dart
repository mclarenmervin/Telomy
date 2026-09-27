import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/widgets/async_action.dart';
import '../../journal/models/journal_entry.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../journal/screens/entry_editor.dart';
import '../data/medication_service.dart';

class MedicationsScreen extends ConsumerWidget {
  const MedicationsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(wellnessProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Medications', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text('Track your prescribed schedule and doses taken.'),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => openEntryEditor(context, EntryKind.medication),
          icon: const Icon(Icons.add),
          label: const Text('Add medication'),
        ),
        const SizedBox(height: 20),
        ...state.when(
          loading: () => [const LinearProgressIndicator()],
          error: (_, _) => [
            TextButton(
              onPressed: () => ref.invalidate(wellnessProvider),
              child: const Text('Unable to load medications. Retry'),
            ),
          ],
          data: (data) {
            final service = const MedicationService();
            final medications = service.summaries(data, DateTime.now());
            return [
              if (medications.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(22),
                    child: Text('No medications recorded.'),
                  ),
                ),
              for (final item in medications)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                item.medication.title,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            Chip(
                              label: Text(item.active ? 'Active' : 'Inactive'),
                            ),
                            PopupMenuButton<String>(
                              onSelected: (value) async {
                                if (value == 'edit') {
                                  await openEntryEditor(
                                    context,
                                    EntryKind.medication,
                                    entry: item.medication,
                                  );
                                } else {
                                  await runAction(
                                    context,
                                    () => ref
                                        .read(wellnessProvider.notifier)
                                        .deleteEntry(item.medication.id),
                                  );
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text('Edit'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete'),
                                ),
                              ],
                            ),
                          ],
                        ),
                        Text(
                          '${item.medication.fields['dose'] ?? ''} · '
                          '${item.medication.fields['frequency'] ?? ''}',
                        ),
                        if (item.medication.fields['time']?.isNotEmpty == true)
                          Text('Scheduled ${item.medication.fields['time']}'),
                        const SizedBox(height: 14),
                        LinearProgressIndicator(value: item.adherence),
                        const SizedBox(height: 6),
                        Text(
                          '${item.takenLastSevenDays} of ${item.expectedLastSevenDays} days logged in the last week',
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonalIcon(
                          onPressed: !item.active || item.takenToday
                              ? null
                              : () => runAction(
                                  context,
                                  () => ref
                                      .read(wellnessProvider.notifier)
                                      .saveEntry(
                                        service.planDose(item.medication),
                                      ),
                                  success: 'Dose recorded',
                                ),
                          icon: Icon(
                            item.takenToday ? Icons.check : Icons.medication,
                          ),
                          label: Text(
                            item.takenToday ? 'Taken today' : 'Mark as taken',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 14),
              const Text(
                'Telomy does not change doses or provide medication instructions. Follow your prescription and contact your clinician or pharmacist with questions.',
                style: TextStyle(fontSize: 12),
              ),
            ];
          },
        ),
      ],
    );
  }
}
