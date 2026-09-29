import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/widgets/async_action.dart';
import '../models/journal_entry.dart';
import '../models/entry_definition.dart';
import '../providers/wellness_provider.dart';
import 'entry_editor.dart';

class JournalScreen extends ConsumerStatefulWidget {
  const JournalScreen({super.key, this.kind});
  final EntryKind? kind;
  @override
  ConsumerState<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends ConsumerState<JournalScreen> {
  String _search = '';
  @override
  Widget build(BuildContext context) {
    final data = ref.watch(wellnessProvider);
    final title = widget.kind == null
        ? 'Your timeline'
        : EntryDefinition.forKind(widget.kind!).title;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 12),
        const Text('Your records, saved on this device.'),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () =>
              openEntryEditor(context, widget.kind ?? EntryKind.event),
          icon: const Icon(Icons.add),
          label: const Text('Add record'),
        ),
        const SizedBox(height: 16),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Search records',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (v) => setState(() => _search = v.toLowerCase()),
        ),
        const SizedBox(height: 16),
        ...data.when(
          loading: () => [const LinearProgressIndicator()],
          error: (_, s) => [
            TextButton(
              onPressed: () => ref.invalidate(wellnessProvider),
              child: const Text('Unable to load. Retry'),
            ),
          ],
          data: (d) {
            final records =
                d.entries
                    .where(
                      (e) =>
                          (widget.kind == null || e.kind == widget.kind) &&
                          '${e.title} ${e.notes}'.toLowerCase().contains(
                            _search,
                          ),
                    )
                    .toList()
                  ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
            if (records.isEmpty) {
              return [
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No records yet. Add your first entry above.'),
                ),
              ];
            }
            return records
                .map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      child: ExpansionTile(
                        title: Text(e.title),
                        subtitle: Text(
                          '${DateFormat.MMMd().add_jm().format(e.recordedAt)} · ${e.kind.name}${e.parentId == null ? '' : ' · Sub-event'}',
                        ),
                        childrenPadding: const EdgeInsets.all(18),
                        expandedCrossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final f in e.fields.entries.where(
                            (f) => f.value.isNotEmpty,
                          ))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                '${EntryDefinition.forKind(e.kind).fields.firstWhere((x) => x.key == f.key, orElse: () => EntryField(f.key, f.key)).label}: ${f.value}',
                              ),
                            ),
                          if (e.notes.isNotEmpty) Text(e.notes),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed: () =>
                                    openEntryEditor(context, e.kind, entry: e),
                                child: const Text('Edit'),
                              ),
                              if (e.kind == EntryKind.event)
                                TextButton(
                                  onPressed: () => openEntryEditor(
                                    context,
                                    EntryKind.event,
                                    parentId: e.id,
                                  ),
                                  child: const Text('Add sub-event'),
                                ),
                              TextButton(
                                onPressed: () async {
                                  final yes = await showDialog<bool>(
                                    context: context,
                                    builder: (c) => AlertDialog(
                                      title: const Text('Delete this record?'),
                                      content: const Text(
                                        'Its sub-events will also be deleted.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(c, false),
                                          child: const Text('Cancel'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(c, true),
                                          child: const Text('Delete'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (yes == true && context.mounted) {
                                    await runAction(
                                      context,
                                      () => ref
                                          .read(wellnessProvider.notifier)
                                          .deleteEntry(e.id),
                                    );
                                  }
                                },
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                )
                .toList();
          },
        ),
      ],
    );
  }
}
