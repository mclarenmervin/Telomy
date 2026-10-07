import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/lab_confirmation.dart';
import '../models/biomarker_result.dart';
import '../models/lab_upload.dart';
import '../widgets/value_crop_view.dart';

/// Where the user checks what we read before it counts.
///
/// Three things this screen must not do, each the reason for a decision here:
///
/// **It must not present a verdict.** Every result arrives `ungraded` until a
/// clinician has signed the reference-range catalog off, so there are no colours
/// and no "normal"/"high" labels — the value as printed, the unit, and the page
/// it came from. An absent grade is a statement about our confidence, and
/// dressing it up as a neutral result would be a claim we cannot support.
///
/// **It must not let a report about someone else through.** One phone per
/// household is common here, and the whole data model assumes one body per
/// account.
///
/// **It must not guess the collection date.** Trending uses it, and a wrong one
/// puts an old panel on today's chart.
class LabConfirmationScreen extends StatefulWidget {
  const LabConfirmationScreen({
    super.key,
    required this.upload,
    required this.results,
    required this.onSubmit,
    this.pageUrls = const {},
  });

  final LabUpload upload;
  final List<BiomarkerResult> results;
  final Future<void> Function(ConfirmationDraft draft) onSubmit;

  /// Short-lived signed URL per page index, for showing each value in context.
  /// Empty is fine — the screen simply shows no crops.
  final Map<int, String> pageUrls;

  @override
  State<LabConfirmationScreen> createState() => _LabConfirmationScreenState();
}

class _LabConfirmationScreenState extends State<LabConfirmationScreen> {
  late final ConfirmationDraft _draft =
      ConfirmationDraft(upload: widget.upload, results: widget.results);
  bool _submitting = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Check your results')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _UnreviewedNotice(),
          const SizedBox(height: 16),
          if (widget.upload.labName != null)
            Text(widget.upload.labName!, style: theme.textTheme.titleMedium),
          if (widget.upload.isHistory)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'This is an older report. It will fill in your history and '
                'will not raise any alerts.',
              ),
            ),
          const SizedBox(height: 20),
          if (_draft.needsPatientConfirmation) _patientCheck(theme),
          if (_draft.needsCollectionDate) _collectionDate(theme),
          const SizedBox(height: 8),
          Text('Values we read', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Check each one against your report. Correct anything we got wrong.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final result in widget.results) _resultTile(result, theme),
          const SizedBox(height: 20),
          for (final blocker in _draft.blockers)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(blocker, style: TextStyle(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('lab-confirm-submit'),
            onPressed: _draft.canSubmit && !_submitting ? _submit : null,
            child: Text(_submitting ? 'Saving…' : 'Add these to my record'),
          ),
        ],
      ),
    );
  }

  Widget _patientCheck(ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Is this your report?', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text('It is in the name of ${widget.upload.patientName}.'),
            const SizedBox(height: 12),
            Row(
              children: [
                ChoiceChip(
                  label: const Text('Yes, that is me'),
                  selected: _draft.patientIsMe == true,
                  onSelected: (_) => setState(() => _draft.patientIsMe = true),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('No, someone else'),
                  selected: _draft.patientIsMe == false,
                  onSelected: (_) => setState(() => _draft.patientIsMe = false),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _collectionDate(ThemeData theme) {
    final chosen = _draft.collectedAt;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('When was the sample taken?', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            // Said plainly rather than hidden: we would rather ask than put the
            // report on the wrong day.
            const Text('We could not read this from the report with confidence.'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today, size: 18),
              label: Text(
                chosen == null
                    ? 'Choose the date'
                    : DateFormat.yMMMMd().format(chosen),
              ),
              onPressed: _pickDate,
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultTile(BiomarkerResult result, ThemeData theme) {
    final decision = _draft.decisionFor(result.id);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Text(_label(result), style: theme.textTheme.titleSmall)),
                // No colour and no verdict. Just what the report says.
                Text(
                  '${result.displayValue} ${result.rawUnit ?? ''}'.trim(),
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            if (result.page != null)
              Text('from page ${result.page! + 1}', style: theme.textTheme.bodySmall),
            // The piece of their own report this number came from. When the
            // text came from OCR this is the only check left: comparing our
            // number against the picture works, against their memory does not.
            ValueCropView(
              imageUrl: widget.pageUrls[result.page],
              bbox: result.bbox,
            ),
            if (result.isCensored)
              Text(
                'The lab reported this as outside what its instrument can '
                'measure, so we will show it but not use it in calculations.',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Correct'),
                  selected: decision?.action == ResultAction.confirm,
                  onSelected: (_) => setState(() => _draft.confirm(result.id)),
                ),
                ChoiceChip(
                  label: const Text('Fix the value'),
                  selected: decision?.action == ResultAction.correct,
                  onSelected: (_) => _promptCorrection(result),
                ),
                ChoiceChip(
                  label: const Text('Not mine / ignore'),
                  selected: decision?.action == ResultAction.reject,
                  onSelected: (_) => setState(() => _draft.reject(result.id)),
                ),
              ],
            ),
            if (decision?.action == ResultAction.correct && decision?.value != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Corrected to ${decision!.value} ${decision.unit ?? ''}'.trim()),
              ),
          ],
        ),
      ),
    );
  }

  String _label(BiomarkerResult result) {
    final name = result.biomarkerId.replaceAll('_', ' ');
    if (result.context == 'standard') return name;
    return '$name (${result.context.replaceAll('_', ' ')})';
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _draft.collectedAt ?? now,
      firstDate: DateTime(now.year - 20),
      // Not beyond today: a sample cannot have been taken in the future.
      lastDate: now,
    );
    if (picked != null) setState(() => _draft.collectedAt = picked);
  }

  Future<void> _promptCorrection(BiomarkerResult result) async {
    final controller = TextEditingController(text: result.rawValue);
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('What does your report say for ${_label(result)}?'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(suffixText: result.rawUnit ?? ''),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, double.tryParse(controller.text.trim())),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value != null) {
      setState(() => _draft.correct(result.id, value: value, unit: result.rawUnit));
    }
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      await widget.onSubmit(_draft);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

/// The blocker, stated to the user rather than hidden.
///
/// `biomarkers.v1.yaml` has not been reviewed by a clinician, so nothing here
/// may be interpreted for them. Saying so is more honest than showing numbers
/// with no explanation and letting them wonder.
class _UnreviewedNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'We show what your report says. We are not telling you whether a '
              'value is normal yet — our reference ranges are still being '
              'reviewed by a clinician.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
