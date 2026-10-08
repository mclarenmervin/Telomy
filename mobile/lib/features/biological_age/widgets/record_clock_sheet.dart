import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/epigenetic_entry.dart';
import '../models/epigenetic_clock.dart';
import '../providers/biological_age_provider.dart';

/// Recording a clock result the user had measured somewhere else.
///
/// The only place in this feature where a number originates on the phone, and
/// the form is shaped around keeping that honest:
///
///   * the **unit is derived from the clock**, never offered as a choice --
///     a picker is an invitation to record a rate as an age;
///   * the **provider is required**, because an unattributed figure reads as
///     ours, which is the one thing it must never do;
///   * nothing here lets the user set `source`. The repository pins it to
///     `third_party` and the table's check constraint pins it again.
class RecordClockSheet extends ConsumerStatefulWidget {
  const RecordClockSheet({super.key});

  static Future<bool?> show(BuildContext context) => showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        builder: (_) => const Padding(
          padding: EdgeInsets.all(22),
          child: RecordClockSheet(),
        ),
      );

  @override
  ConsumerState<RecordClockSheet> createState() => _RecordClockSheetState();
}

class _RecordClockSheetState extends ConsumerState<RecordClockSheet> {
  String _clock = 'horvath';
  final _value = TextEditingController();
  final _provider = TextEditingController();
  DateTime _collectedAt = DateTime.now();
  Map<String, String> _errors = const {};
  bool _saving = false;
  String? _failure;

  @override
  void dispose() {
    _value.dispose();
    _provider.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final errors = validateClockEntry(
      clock: _clock,
      value: _value.text,
      provider: _provider.text,
      collectedAt: _collectedAt,
      today: DateTime.now(),
    );
    setState(() {
      _errors = errors;
      _failure = null;
    });
    if (errors.isNotEmpty) return;

    final user = ref.read(authProvider).asData?.value;
    if (user == null) return;

    setState(() => _saving = true);
    try {
      await ref.read(epigeneticRepositoryProvider).record(
            userId: user.id,
            clock: _clock,
            value: double.parse(_value.text.trim()),
            unit: unitFor(_clock),
            provider: _provider.text.trim(),
            collectedAt: _collectedAt,
          );
      // The list is a FutureProvider, so it has to be told the data moved.
      ref.invalidate(epigeneticClocksProvider);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      // Said plainly rather than swallowed. A save that silently did nothing is
      // worse than one that admits it failed.
      if (mounted) {
        setState(() {
          _saving = false;
          _failure = 'That could not be saved. Check your connection and retry.';
        });
      }
    }
  }

  /// Clear one field's complaint as soon as the person acts on it.
  ///
  /// Without this the message sits under corrected input until the next Save,
  /// so the form reads as still broken while the user looks at something they
  /// have already fixed.
  void _clear(String field) {
    if (_errors.containsKey(field)) {
      setState(() => _errors = {..._errors}..remove(field));
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _collectedAt,
      firstDate: DateTime(2013),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _collectedAt = picked);
      _clear('collectedAt');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Record a clock result', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'From an epigenetic test you have had done elsewhere. We will show '
            'it alongside your results and will not calculate it ourselves.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 18),
          DropdownButtonFormField<String>(
            initialValue: _clock,
            decoration: InputDecoration(
              labelText: 'Clock',
              errorText: _errors['clock'],
            ),
            items: [
              for (final clock in knownClocks)
                DropdownMenuItem(
                  value: clock,
                  child: Text(EpigeneticClock.labelOf(clock)),
                ),
            ],
            onChanged: (value) {
              setState(() => _clock = value ?? _clock);
              _clear('clock');
              // The plausible range depends on the clock -- a value rejected as
              // an age may be fine as a pace -- so that complaint is stale too.
              _clear('value');
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _value,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Result',
              // The unit is shown, not chosen.
              suffixText: unitFor(_clock) == 'pace' ? 'x per year' : 'years',
              helperText: unitFor(_clock) == 'pace'
                  ? 'A rate of ageing, usually near 1.'
                  : null,
              errorText: _errors['value'],
            ),
            onChanged: (_) => _clear('value'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _provider,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Measured by',
              hintText: 'The laboratory or service that ran the test',
              errorText: _errors['provider'],
            ),
            onChanged: (_) => _clear('provider'),
          ),
          const SizedBox(height: 12),
          InputDecorator(
            decoration: InputDecoration(
              labelText: 'Sample taken',
              errorText: _errors['collectedAt'],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(DateFormat('d MMMM y').format(_collectedAt)),
                TextButton(onPressed: _pickDate, child: const Text('Change')),
              ],
            ),
          ),
          if (_failure case final failure?) ...[
            const SizedBox(height: 12),
            Text(failure, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving…' : 'Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
