import 'package:flutter/material.dart';

import '../../biological_age/data/biological_age_view.dart' show markerLabel;
import '../models/clinical_insight.dart';

/// One finding, with the trail that says who stands behind it.
///
/// The card carries one distinction that the rest of this phase exists to make
/// true: either a named clinician read these exact words and signed them, or
/// nobody did. The two most expensive mistakes available here are showing a
/// reviewer who did not review, and burying the fact that nobody did — so the
/// status is always stated in words, never in a colour alone.
class InsightCard extends StatefulWidget {
  const InsightCard({
    super.key,
    required this.insight,
    required this.onDispute,
    required this.onDismiss,
  });

  final ClinicalInsight insight;

  /// Takes the reason. A dispute without one is a dismissal with a different
  /// label, and the column is NOT NULL when `disputed_at` is set.
  final void Function(String reason) onDispute;

  final VoidCallback onDismiss;

  @override
  State<InsightCard> createState() => _InsightCardState();
}

class _InsightCardState extends State<InsightCard> {
  final _reason = TextEditingController();
  bool _disputing = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _send() {
    final reason = _reason.text.trim();
    // Empty is not sent. The database would refuse it, and a constraint
    // violation is not something a user can interpret.
    if (reason.isEmpty) return;
    widget.onDispute(reason);
    setState(() => _disputing = false);
  }

  @override
  Widget build(BuildContext context) {
    final insight = widget.insight;
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ReviewBadge(insight: insight),
            const SizedBox(height: 12),
            // Said in words, like the review badge above it. This is the first
            // kind of insight the user can be told to act on, and "a number
            // moved" and "consider taking this" should not look alike.
            if (insight.isSupplement) ...[
              _KindChip(
                icon: Icons.medication_outlined,
                label: 'Supplement suggestion',
              ),
              const SizedBox(height: 10),
            ],
            if (insight.title.isNotEmpty)
              Text(insight.title, style: theme.textTheme.titleMedium),
            if (insight.title.isNotEmpty) const SizedBox(height: 8),
            if (insight.body.isNotEmpty)
              // As signed. A clinician put their registration number against
              // these words, so the app does not summarise or rephrase them.
              Text(insight.body, style: theme.textTheme.bodyMedium),
            if (insight.evidence.isNotEmpty) ...[
              const SizedBox(height: 16),
              _Evidence(evidence: insight.evidence),
            ],
            if (insight.isDisputed) ...[
              const SizedBox(height: 16),
              _DisputeNote(reason: insight.disputeReason),
            ],
            if (_disputing) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _reason,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: 'What is wrong about it?',
                  // Found on a device: this said "goes to the clinician who
                  // reviewed it" on a card whose own badge said nobody had.
                  // The unreviewed case is the one where the dispute matters
                  // most, and promising a reviewer who does not exist is the
                  // same false claim the badge above is there to prevent.
                  helperText: insight.wasReviewed
                      ? 'This goes to the clinician who reviewed it. It does '
                          'not remove the finding.'
                      : 'This goes to the clinician who picks it up. It does '
                          'not remove the finding.',
                  helperMaxLines: 3,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => setState(() => _disputing = false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _send, child: const Text('Send')),
                ],
              ),
            ] else ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  // Two actions, not one. "I have read this" and "this is
                  // wrong about me" are different things to tell us, and only
                  // one of them is a reason for anybody to look again.
                  if (!insight.isDisputed)
                    TextButton(
                      onPressed: () => setState(() => _disputing = true),
                      child: const Text('This is wrong'),
                    ),
                  const Spacer(),
                  if (!insight.isDismissed)
                    TextButton(
                      onPressed: widget.onDismiss,
                      child: const Text('Dismiss'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Who stands behind this finding, in words.
class _ReviewBadge extends StatelessWidget {
  const _ReviewBadge({required this.insight});

  final ClinicalInsight insight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reviewed = insight.wasReviewed;

    // Colour carries no information on its own here. This is the one
    // distinction in the product that must never be conveyed by a hue.
    final label = reviewed
        ? 'Reviewed by ${insight.reviewerName}'
            '${insight.reviewerRegistration?.isNotEmpty ?? false ? ' · ${insight.reviewerRegistration}' : ''}'
        : 'Not yet reviewed by a clinician';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          reviewed ? Icons.verified_user_outlined : Icons.schedule_outlined,
          size: 18,
          color: reviewed
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: reviewed
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (!reviewed)
                Text(
                  'We are telling you what we noticed. Nobody has checked it '
                  'yet.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What kind of finding this is, for the kinds where it changes what to do.
class _KindChip extends StatelessWidget {
  const _KindChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSecondaryContainer),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSecondaryContainer),
          ),
        ],
      ),
    );
  }
}

/// The values the finding rests on.
///
/// The user is entitled to the same workings the clinician saw.
class _Evidence extends StatelessWidget {
  const _Evidence({required this.evidence});

  final List<InsightEvidence> evidence;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Based on', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        for (final entry in evidence)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(_line(entry), style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}

/// One evidence entry as a line.
///
/// An exhaustive switch, which is the reason the evidence is a sealed union: a
/// shape added to the backend without a case here stops the analyzer rather
/// than rendering a blank bullet under "Based on". `UnknownEvidence` is the
/// deliberate exception -- it exists so that an app version older than the
/// backend says what it cannot show instead of pretending there is nothing.
String _line(InsightEvidence entry) => switch (entry) {
      MeasurementEvidence(:final biomarkerId, :final collectedAt, :final labName) =>
        [
          '${markerLabel(biomarkerId)} ${entry.summary}'.trim(),
          if (collectedAt != null) _printed(collectedAt),
          if (labName?.isNotEmpty ?? false) labName!,
        ].join(' · '),
      // The citation rather than the range's version string: the user is being
      // told what the threshold is and where it comes from, and `global.v1`
      // means nothing to them. The version is kept on the row for the trail.
      RangeEvidence(:final citation) => [
          entry.summary,
          if (citation?.isNotEmpty ?? false) citation!,
        ].join(' · '),
      RuleEvidence(:final citation) => [
          entry.summary,
          if (citation?.isNotEmpty ?? false) citation!,
        ].join(' · '),
      // The note is already in the signed body, where the clinician's revision
      // may have changed it. Repeating it here would either duplicate that
      // sentence or quietly contradict it.
      InteractionEvidence() => entry.summary,
      UnknownEvidence() => entry.summary,
    };


class _DisputeNote extends StatelessWidget {
  const _DisputeNote({required this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('You said this is wrong', style: theme.textTheme.labelMedium),
          if (reason?.isNotEmpty ?? false) ...[
            const SizedBox(height: 4),
            Text(reason!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _printed(DateTime date) =>
    '${date.day} ${_months[date.month - 1]} ${date.year}';
