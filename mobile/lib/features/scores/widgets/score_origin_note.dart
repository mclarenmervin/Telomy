import 'package:flutter/material.dart';

import '../../../core/vocabulary/vocabulary.dart';
import '../data/score_source.dart';

/// Says plainly where a score came from.
///
/// During the shadow period the app still shows its own estimate while the
/// server's is computed and compared, and a user is entitled to know which one
/// they are looking at. Stating it in words rather than a colour or an icon is
/// the same discipline the activity report already follows for severity.
///
/// **This was `Prov` before `Prov` existed.** It is the component F9 found
/// already here — source, and a confidence, under a number — and it is now
/// built on the real one rather than beside it. The alternative was two
/// provenance components with two renderings, and the one on the readiness
/// screen would have drifted from the one on the other eleven.
class ScoreOriginNote extends StatelessWidget {
  const ScoreOriginNote({super.key, required this.resolved, this.divergence});

  final ResolvedScore resolved;

  /// Server minus local, when both exist. Shown only in debug builds: it is
  /// engineering evidence, not something to put in front of a user.
  final int? divergence;

  @override
  Widget build(BuildContext context) {
    final snapshot = resolved.snapshot;

    final (source, confidence, basis) = switch (resolved.origin) {
      ScoreOrigin.server => (
          'your full history',
          // A server score computed from a partial day is still an estimate,
          // and `data_quality` is the column that already knows.
          snapshot?.dataQuality == 'partial'
              ? Confidence.estimated
              : Confidence.measured,
          snapshot == null
              ? 'computed by the Telomy service'
              : _serverBasis(snapshot),
        ),
      ScoreOrigin.offline => (
          'this phone',
          Confidence.estimated,
          'the data this phone holds, not your full history',
        ),
      ScoreOrigin.none => (
          'nothing yet',
          Confidence.insufficient,
          'Not enough data to estimate this',
        ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Prov(
          source: source,
          when: snapshot?.asOf,
          confidence: confidence,
          basis: basis,
        ),
        // The divergence rides along only where engineers see it.
        if (divergence != null && _showDivergence)
          T(
            'server ${divergence! >= 0 ? '+' : ''}$divergence',
            v: TextVariant.label,
            muted: true,
          ),
      ],
    );
  }

  /// What the server's number actually rests on.
  ///
  /// The missing inputs are named rather than counted. "Computed without your
  /// sleep" is a thing somebody can act on; "data quality: partial" is not.
  String _serverBasis(dynamic snapshot) {
    final missing = (snapshot.missingInputs as List).cast<String>();
    if (missing.isEmpty) return 'every input this model takes';
    return 'computed without ${missing.join(', ')}';
  }
}

const _showDivergence = bool.fromEnvironment('SHOW_SCORE_DIVERGENCE');
