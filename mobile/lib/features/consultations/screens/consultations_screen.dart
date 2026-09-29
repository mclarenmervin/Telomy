import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/widgets/async_action.dart';
import '../../journal/models/journal_entry.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../marketplace/data/marketplace_catalog.dart';
import '../data/consultation_service.dart';

class ConsultationsScreen extends ConsumerWidget {
  const ConsultationsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(wellnessProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Consultations', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text('Book and manage wellness sessions in one place.'),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => _openBooking(context, ref),
          icon: const Icon(Icons.calendar_month_outlined),
          label: const Text('Book consultation'),
        ),
        const SizedBox(height: 20),
        ...state.when(
          loading: () => [const LinearProgressIndicator()],
          error: (_, _) => [const Text('Unable to load consultations.')],
          data: (data) {
            final service = const ConsultationService();
            final items = service.consultations(data);
            return [
              if (items.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(22),
                    child: Text('No consultations booked.'),
                  ),
                ),
              for (final item in items)
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
                                item.title,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            Chip(
                              label: Text(
                                service.status(item, DateTime.now()).name,
                              ),
                            ),
                          ],
                        ),
                        Text(item.fields['provider'] ?? ''),
                        const SizedBox(height: 10),
                        Text(
                          DateFormat.yMMMd().add_jm().format(item.recordedAt),
                        ),
                        Text(
                          '${item.fields['duration']} min · ${item.fields['delivery']}',
                        ),
                        if (item.notes.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(item.notes),
                        ],
                        const SizedBox(height: 12),
                        if (service.status(item, DateTime.now()) ==
                            ConsultationStatus.upcoming)
                          Wrap(
                            spacing: 8,
                            children: [
                              OutlinedButton(
                                onPressed: () => _setStatus(
                                  context,
                                  ref,
                                  item,
                                  ConsultationStatus.cancelled,
                                ),
                                child: const Text('Cancel'),
                              ),
                              FilledButton.tonal(
                                onPressed: () => _setStatus(
                                  context,
                                  ref,
                                  item,
                                  ConsultationStatus.completed,
                                ),
                                child: const Text('Mark completed'),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
            ];
          },
        ),
      ],
    );
  }

  Future<void> _setStatus(
    BuildContext context,
    WidgetRef ref,
    JournalEntry item,
    ConsultationStatus status,
  ) => runAction(
    context,
    () => ref
        .read(wellnessProvider.notifier)
        .saveEntry(const ConsultationService().withStatus(item, status)),
    success: 'Consultation ${status.name}',
  );

  Future<void> _openBooking(BuildContext context, WidgetRef ref) async {
    MarketplaceListing selected = MarketplaceCatalog.listings.first;
    DateTime date = DateTime.now().add(const Duration(days: 1));
    final notes = TextEditingController();
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            8,
            24,
            MediaQuery.viewInsetsOf(context).bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Book consultation',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<MarketplaceListing>(
                  initialValue: selected,
                  decoration: const InputDecoration(labelText: 'Service'),
                  items: [
                    for (final item in MarketplaceCatalog.listings)
                      DropdownMenuItem(value: item, child: Text(item.name)),
                  ],
                  onChanged: (value) {
                    if (value != null) setSheetState(() => selected = value);
                  },
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Appointment'),
                  subtitle: Text(DateFormat.yMMMd().add_jm().format(date)),
                  trailing: const Icon(Icons.edit_calendar_outlined),
                  onTap: () async {
                    final day = await showDatePicker(
                      context: context,
                      initialDate: date,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (day == null || !context.mounted) return;
                    final time = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(date),
                    );
                    if (time != null) {
                      setSheetState(
                        () => date = DateTime(
                          day.year,
                          day.month,
                          day.day,
                          time.hour,
                          time.minute,
                        ),
                      );
                    }
                  },
                ),
                TextField(
                  controller: notes,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Notes or goals',
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(sheetContext, true),
                    child: Text(
                      'Book for ₹${selected.price.toStringAsFixed(0)}',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed == true && context.mounted) {
      await runAction(
        context,
        () => ref
            .read(wellnessProvider.notifier)
            .saveEntry(
              const ConsultationService().booking(
                listing: selected,
                date: date,
                notes: notes.text.trim(),
              ),
            ),
        success: 'Consultation booked',
      );
    }
    notes.dispose();
  }
}
