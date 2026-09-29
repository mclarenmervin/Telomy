import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/widgets/async_action.dart';
import '../models/journal_entry.dart';
import '../models/entry_definition.dart';
import '../providers/wellness_provider.dart';

Future<void> openEntryEditor(
  BuildContext context,
  EntryKind kind, {
  JournalEntry? entry,
  String? parentId,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => EntryEditor(kind: kind, entry: entry, parentId: parentId),
  ),
);

class EntryEditor extends ConsumerStatefulWidget {
  const EntryEditor({super.key, required this.kind, this.entry, this.parentId});
  final EntryKind kind;
  final JournalEntry? entry;
  final String? parentId;
  @override
  ConsumerState<EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends ConsumerState<EntryEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title, _notes;
  late final Map<String, TextEditingController> _fields;
  late DateTime _time;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.entry?.title);
    _notes = TextEditingController(text: widget.entry?.notes);
    _time = widget.entry?.recordedAt ?? DateTime.now();
    _fields = {
      for (final f in EntryDefinition.forKind(widget.kind).fields)
        f.key: TextEditingController(text: widget.entry?.fields[f.key]),
    };
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (widget.kind != EntryKind.plan && _time.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Recorded events cannot be in the future.'),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    final fields = {
      for (final f in _fields.entries) f.key: f.value.text.trim(),
    };
    final fresh = JournalEntry.create(
      kind: widget.kind,
      title: _title.text.trim(),
      recordedAt: _time,
      notes: _notes.text.trim(),
      fields: fields,
      parentId: widget.parentId,
    );
    final entry = widget.entry == null
        ? fresh
        : JournalEntry(
            id: widget.entry!.id,
            kind: fresh.kind,
            title: fresh.title,
            recordedAt: fresh.recordedAt,
            notes: fresh.notes,
            fields: fresh.fields,
            parentId: widget.entry!.parentId,
          );
    final saved = await runAction(
      context,
      () => ref.read(wellnessProvider.notifier).saveEntry(entry),
    );
    if (!mounted) return;
    if (saved) {
      Navigator.pop(context);
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final definition = EntryDefinition.forKind(widget.kind);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry == null ? 'Add record' : 'Edit record'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(
                    definition.title,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(definition.hint),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _title,
                    enabled: !_saving,
                    decoration: const InputDecoration(labelText: 'Title'),
                    maxLength: 120,
                    validator: (v) => (v?.trim().isNotEmpty ?? false)
                        ? null
                        : 'Enter a title',
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Date and time'),
                    subtitle: Text(DateFormat.yMMMd().add_jm().format(_time)),
                    trailing: const Icon(Icons.edit_calendar),
                    onTap: _saving
                        ? null
                        : () async {
                            final date = await showDatePicker(
                              context: context,
                              initialDate: _time,
                              firstDate: DateTime(1900),
                              lastDate: widget.kind == EntryKind.plan
                                  ? DateTime.now().add(
                                      const Duration(days: 3650),
                                    )
                                  : DateTime.now(),
                            );
                            if (date == null || !context.mounted) return;
                            final time = await showTimePicker(
                              context: context,
                              initialTime: TimeOfDay.fromDateTime(_time),
                            );
                            if (time != null && mounted) {
                              setState(
                                () => _time = DateTime(
                                  date.year,
                                  date.month,
                                  date.day,
                                  time.hour,
                                  time.minute,
                                ),
                              );
                            }
                          },
                  ),
                  for (final field in definition.fields)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: TextFormField(
                        controller: _fields[field.key],
                        enabled: !_saving,
                        maxLength: field.numeric ? 12 : 240,
                        decoration: InputDecoration(labelText: field.label),
                        keyboardType: field.numeric
                            ? const TextInputType.numberWithOptions(
                                decimal: true,
                              )
                            : TextInputType.text,
                        validator: (v) {
                          if ((v?.trim().isEmpty ?? true) && !field.required) {
                            return null;
                          }
                          if (!field.numeric) return null;
                          final n = double.tryParse(v ?? '');
                          return n == null ||
                                  !n.isFinite ||
                                  n < 0 ||
                                  n > field.max
                              ? 'Enter a value from 0 to ${field.max.toStringAsFixed(0)}'
                              : null;
                        },
                      ),
                    ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _notes,
                    enabled: !_saving,
                    maxLines: 4,
                    maxLength: 4000,
                    decoration: const InputDecoration(
                      labelText: 'Notes / plan details',
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving…' : 'Save record'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
