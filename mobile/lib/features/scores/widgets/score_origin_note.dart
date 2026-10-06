import 'package:flutter/material.dart';

import '../data/score_source.dart';

/// Says plainly where a number came from.
///
/// During the shadow period the app still shows its own estimate while the
/// server's is computed and compared, and a user is entitled to know which one
/// they are looking at. Stating it in words rather than a colour or an icon is
/// the same discipline the activity report already follows for severity.
class ScoreOriginNote extends StatelessWidget {
  const ScoreOriginNote({super.key, required this.resolved, this.divergence});

  final ResolvedScore resolved;

  /// Server minus local, when both exist. Shown only in debug builds: it is
  /// engineering evidence, not something to put in front of a user.
  final int? divergence;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, text) = switch (resolved.origin) {
      ScoreOrigin.server => (
          Icons.cloud_done_outlined,
          'Calculated from your full history.',
        ),
      ScoreOrigin.offline => (
          Icons.phone_iphone_outlined,
          'Estimated on this phone from the data it holds.',
        ),
      ScoreOrigin.none => (
          Icons.help_outline,
          'Not enough data yet to estimate this.',
        ),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: theme.colorScheme.outline),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            // The divergence rides along only where engineers see it.
            divergence != null && _showDivergence
                ? '$text  (server ${divergence! >= 0 ? '+' : ''}$divergence)'
                : text,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
      ],
    );
  }
}

const _showDivergence = bool.fromEnvironment('SHOW_SCORE_DIVERGENCE');
