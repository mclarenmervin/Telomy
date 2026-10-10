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
        for (final point in evidence)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              [
                '${markerLabel(point.biomarkerId)} ${point.display}',
                if (point.collectedAt != null) _printed(point.collectedAt!),
                if (point.labName?.isNotEmpty ?? false) point.labName!,
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

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
