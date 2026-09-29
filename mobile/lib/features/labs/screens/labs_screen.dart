import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/widgets/async_action.dart';
import '../../journal/models/journal_entry.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../journal/screens/entry_editor.dart';
import '../data/lab_analysis.dart';

class LabsScreen extends ConsumerStatefulWidget {
  const LabsScreen({super.key});
  @override
  ConsumerState<LabsScreen> createState() => _LabsScreenState();
}

class _LabsScreenState extends ConsumerState<LabsScreen> {
  String _query = '';
  String _category = 'All';

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(wellnessProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Lab results', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 10),
        const Text(
          'Keep report values and reference ranges together over time.',
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => openEntryEditor(context, EntryKind.lab),
          icon: const Icon(Icons.add),
          label: const Text('Add lab result'),
        ),
        const SizedBox(height: 18),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Search biomarkers',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) =>
              setState(() => _query = value.trim().toLowerCase()),
        ),
        const SizedBox(height: 14),
        ...state.when(
          loading: () => [const LinearProgressIndicator()],
          error: (_, _) => [
            TextButton(
              onPressed: () => ref.invalidate(wellnessProvider),
              child: const Text('Unable to load lab results. Retry'),
            ),
          ],
          data: (data) {
            final analysis = LabAnalysis(data);
            final categories = <String>{
              'All',
              for (final item in analysis.results)
                if (item.fields['category']?.trim().isNotEmpty == true)
                  item.fields['category']!.trim(),
            }.toList();
            final selected = categories.contains(_category) ? _category : 'All';
            final visible = analysis.results.where((item) {
              final matchesQuery =
                  _query.isEmpty ||
                  item.title.toLowerCase().contains(_query) ||
                  (item.fields['laboratory'] ?? '').toLowerCase().contains(
                    _query,
                  );
              return matchesQuery &&
                  (selected == 'All' || item.fields['category'] == selected);
            }).toList();
            final flagged = analysis.results.where((item) {
              final status = analysis.status(item);
              return status == LabResultStatus.high ||
                  status == LabResultStatus.low;
            }).length;
            return [
              Wrap(
                spacing: 8,
                children: [
                  for (final category in categories)
                    ChoiceChip(
                      label: Text(category),
                      selected: selected == category,
                      onSelected: (_) => setState(() => _category = category),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _Stat('Results', '${analysis.results.length}'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: _Stat('Outside range', '$flagged')),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Stat(
                      'Biomarkers',
                      '${analysis.byBiomarker.length}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (visible.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(22),
                    child: Text('No matching lab results.'),
                  ),
                ),
              for (final result in visible)
                _ResultCard(
                  result: result,
                  status: analysis.status(result),
                  history: analysis.historyFor(result),
                  onEdit: () =>
                      openEntryEditor(context, EntryKind.lab, entry: result),
                  onDelete: () => runAction(
                    context,
                    () => ref
                        .read(wellnessProvider.notifier)
                        .deleteEntry(result.id),
                  ),
                ),
            ];
          },
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
  );
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.result,
    required this.status,
    required this.history,
    required this.onEdit,
    required this.onDelete,
  });
  final JournalEntry result;
  final LabResultStatus status;
  final List<JournalEntry> history;
  final VoidCallback onEdit, onDelete;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      LabResultStatus.low || LabResultStatus.high => Colors.orange.shade700,
      LabResultStatus.withinRange => Colors.green.shade700,
      LabResultStatus.rangeUnavailable => Theme.of(context).colorScheme.outline,
    };
    final label = switch (status) {
      LabResultStatus.low => 'Below range',
      LabResultStatus.high => 'Above range',
      LabResultStatus.withinRange => 'Within range',
      LabResultStatus.rangeUnavailable => 'No range',
    };
    final low = result.fields['rangeLow'] ?? '';
    final high = result.fields['rangeHigh'] ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    result.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) =>
                      value == 'edit' ? onEdit() : onDelete(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
            Text(
              '${result.fields['value']} ${result.fields['unit'] ?? ''}',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              children: [
                Chip(
                  avatar: Icon(Icons.circle, size: 10, color: color),
                  label: Text(label),
                ),
                if (low.isNotEmpty || high.isNotEmpty)
                  Chip(label: Text('Reference $low – $high')),
                if (history.length > 1)
                  Chip(label: Text('${history.length} results in trend')),
              ],
            ),
            Text(
              '${DateFormat.yMMMd().format(result.recordedAt)}'
              '${result.fields['laboratory']?.isNotEmpty == true ? ' · ${result.fields['laboratory']}' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
