import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_status.dart';
import '../../app/theme/app_typography.dart';

/// How much a number is worth, and why.
///
/// **Not a 0–1 number, deliberately.** The prototype's `ConfBar` takes a
/// fraction and renders a gradient. We have no fraction to give it: what this
/// product actually holds is an evidence *count* — 60 matching days, 8
/// sessions, 24 hours observed, 14 effective samples after the autocorrelation
/// correction — and mapping a count onto 73% would be manufacturing a
/// statistic, which is the one thing every engine in this codebase refuses to
/// do. So the confidence is a named band and the count travels with it as
/// `basis`, always.
///
/// **`unreviewed` is a different axis from the rest and that is the point.**
/// "We measured this across eight of your sessions" can be strong evidence
/// whose *explanation* no clinician has signed. Rendering that as low
/// confidence would tell somebody their own data is unreliable, which is both
/// untrue and the opposite of what we mean. It is the only value here that
/// says nothing about the measurement.
enum Confidence {
  /// Measured on this person, with enough of it to mean something.
  measured,

  /// Measured, but thin — a partial night, a short window, a day the provider
  /// only had a few hours of.
  estimated,

  /// Not enough to say anything yet. Still shown, because "we do not know
  /// yet" is a fact about them and silence is not.
  insufficient,

  /// The number is real; the sentence explaining it is not signed off.
  unreviewed,

  /// Not measured on this person at all. Decision 5: a simulated number that
  /// reads as a measurement is the single worst outcome available here.
  simulated;

  String get label => switch (this) {
        Confidence.measured => 'Measured',
        Confidence.estimated => 'Estimated',
        Confidence.insufficient => 'Not enough yet',
        Confidence.unreviewed => 'Nobody has reviewed this',
        Confidence.simulated => 'Simulated',
      };

  AppStatus get status => switch (this) {
        Confidence.measured => AppStatus.inRange,
        Confidence.estimated => AppStatus.typical,
        Confidence.insufficient => AppStatus.notDetected,
        Confidence.unreviewed => AppStatus.notReviewed,
        Confidence.simulated => AppStatus.simulated,
      };

  /// How much of the bar is filled, out of [ConfBar.segments]. Null means the
  /// bar is not drawn at all — see `unreviewed` above.
  int? get strength => switch (this) {
        Confidence.measured => 3,
        Confidence.estimated => 2,
        Confidence.insufficient => 1,
        Confidence.unreviewed => null,
        Confidence.simulated => null,
      };
}

/// Source · when · confidence, under a number.
///
/// This is the roadmap's F01 arriving as a component rather than as a feature,
/// and from F9 onward a number rendered without it is a review failure. That
/// rule is only cheap to hold because this exists first.
///
/// **The vocabulary it absorbs rather than reinvents.** Four screens shipped
/// in F8 already write a provenance sentence by hand, and those sentences were
/// read before this was designed:
///
///   environment  "From open-meteo." · "Only 18 hours of this day were
///                available."
///   therapies    "Across 8 sessions — 2 more were left out because something
///                else you logged overlapped them."
///   correlations "They move together · 60 matching days"
///   genetics     the rsid under the label, and "Nobody has reviewed what they
///                mean yet, so we do not say."
///   scores       "Calculated from your full history." / "Estimated on this
///                phone from the data it holds."
///
/// Every one of those is a source, a window and a confidence, written five
/// ways. [source] is required for the reason the phase exists: a number whose
/// origin is a sentence somebody remembered to type is a number that will one
/// day be rendered bare.
class Prov extends StatelessWidget {
  const Prov({
    super.key,
    required this.source,
    required this.confidence,
    required this.basis,
    this.when,
    this.whenLabel,
  });

  /// Who or what produced this. "open-meteo", "your ring", "this phone",
  /// "your own sessions", "a 23andMe export".
  final String source;

  /// When it was true. A date for a measurement.
  final DateTime? when;

  /// When it was true, in words, for a number that is a window rather than a
  /// moment: "the last 60 days", "across October". Some numbers have no
  /// instant and forcing one would be a false precision.
  final String? whenLabel;

  final Confidence confidence;

  /// What the confidence rests on, in the user's own units: "24 hours
  /// observed", "60 matching days", "across 8 sessions". Required, because a
  /// confidence with no basis is an opinion.
  final String basis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = confidence.status.tone(theme.brightness);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    final parts = <String>[
      'From $source',
      if (whenLabel != null && whenLabel!.isNotEmpty)
        whenLabel!
      else if (when != null)
        DateFormat('d MMM yyyy').format(when!),
      basis,
    ];

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xxs),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xxs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // The word, always. A confidence that is only a colour fails for a
          // colour-blind reader and in a screenshot pasted into a report.
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xs, vertical: 2),
            decoration: BoxDecoration(
              color: tone.background,
              borderRadius: BorderRadius.circular(AppRadii.chip),
            ),
            child: Text(
              confidence.label,
              style: AppTypography.scale(TextVariant.label, theme.textTheme)
                  .copyWith(color: tone.foreground),
            ),
          ),
          Text(parts.join(' · '), style: muted),
        ],
      ),
    );
  }
}

/// One cell of the confidence bar. A widget rather than a painted rectangle so
/// that a test can count the filled ones.
class ConfSegment extends StatelessWidget {
  const ConfSegment({super.key, required this.filled});

  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 18,
      height: 5,
      decoration: BoxDecoration(
        color: filled
            ? theme.colorScheme.primary
            : theme.colorScheme.outlineVariant,
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
    );
  }
}

/// F02's confidence gradient, as discrete steps with a reason under them.
///
/// Discrete because three bands we can defend beat a continuum we cannot, and
/// because a smooth gradient invites the reader to see 70% where we meant
/// "measured, and there is a decent amount of it".
///
/// Draws no bar at all for [Confidence.unreviewed] and
/// [Confidence.simulated]: neither is a quantity of evidence. The first is a
/// missing signature and the second is not evidence about this person, and
/// filling two of three segments for either would be the most misleading thing
/// on the screen.
class ConfBar extends StatelessWidget {
  const ConfBar({super.key, required this.confidence, required this.basis});

  static const segments = 3;

  final Confidence confidence;
  final String basis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strength = confidence.strength;
    final tone = confidence.status.tone(theme.brightness);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (strength != null) ...[
          for (var i = 0; i < segments; i++)
            Padding(
              padding: const EdgeInsets.only(right: 3),
              child: ConfSegment(filled: i < strength),
            ),
          const SizedBox(width: AppSpacing.xs),
        ] else ...[
          Icon(Icons.info_outline, size: 14, color: tone.foreground),
          const SizedBox(width: AppSpacing.xxs),
        ],
        Flexible(
          child: Text(
            basis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
