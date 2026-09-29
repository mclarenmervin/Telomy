import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../journal/models/journal_entry.dart';
import '../../journal/screens/entry_editor.dart';
import '../../dashboard/widgets/metric_card.dart';

class TimelineScreen extends ConsumerStatefulWidget {
  const TimelineScreen({super.key});
  @override
  ConsumerState<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends ConsumerState<TimelineScreen> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final data = ref.watch(wellnessProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your timeline',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 12),
              const Text(
                'Manual records and ring observations, ordered by time.',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: data.asData == null
                    ? null
                    : () => openEntryEditor(context, EntryKind.event),
                icon: const Icon(Icons.add),
                label: const Text('Add event'),
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: const InputDecoration(
                  labelText: 'Search timeline',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => _query = v.toLowerCase()),
              ),
            ],
          ),
        ),
        Expanded(
          child: data.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, s) => Center(
              child: TextButton(
                onPressed: () => ref.invalidate(wellnessProvider),
                child: const Text('Retry loading timeline'),
              ),
            ),
            data: (d) {
              final items =
                  <
                        ({
                          DateTime at,
                          String title,
                          String detail,
                          JournalEntry? entry,
                        })
                      >[
                        for (final e in d.entries)
                          (
                            at: e.recordedAt,
                            title: e.title,
                            detail:
                                '${e.kind.name}${e.parentId == null ? '' : ' · Sub-event'}${e.notes.isEmpty ? '' : ' · ${e.notes}'}',
                            entry: e,
                          ),
                        for (final m in d.measurements)
                          (
                            at: m.recordedAt,
                            title:
                                '${metricLabel(m.measurementType)} · ${metricValue(m)} ${m.unit}',
                            detail:
                                '${m.source.name}${m.deviceId == null ? '' : ' · Ring reading'}',
                            entry: null,
                          ),
                      ]
                      .where(
                        (e) => '${e.title} ${e.detail}'.toLowerCase().contains(
                          _query,
                        ),
                      )
                      .toList()
                    ..sort((a, b) => b.at.compareTo(a.at));
              if (items.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No matching records yet. Add an event or sync a reading.',
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final item = items[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        leading: Icon(
                          item.entry == null
                              ? Icons.monitor_heart_outlined
                              : Icons.timeline,
                        ),
                        title: Text(item.title),
                        subtitle: Text(
                          '${DateFormat.yMMMd().add_jm().format(item.at)}\n${item.detail}',
                        ),
                        isThreeLine: true,
                        onTap: item.entry == null
                            ? null
                            : () => openEntryEditor(
                                context,
                                item.entry!.kind,
                                entry: item.entry,
                              ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
