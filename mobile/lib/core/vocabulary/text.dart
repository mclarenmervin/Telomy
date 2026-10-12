import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_status.dart';
import '../../app/theme/app_typography.dart';

export '../../app/theme/app_typography.dart' show TextVariant;

/// One typographic scale, and the only way text is set.
///
/// Named `T` after the prototype's component, which every one of its 73
/// screens uses and which is most of why they look like one product. The
/// alternative — each screen reaching into `textTheme` for whatever looked
/// right — is what this codebase was doing, and the drift is already visible:
/// three different sizes of "small grey caption" across the F8 screens.
class T extends StatelessWidget {
  const T(
    this.text, {
    super.key,
    this.v = TextVariant.body,
    this.color,
    this.muted = false,
    this.align,
    this.maxLines,
  });

  final String text;
  final TextVariant v;
  final Color? color;

  /// The commonest colour override by a wide margin, so it is a flag rather
  /// than a `Theme.of(context).colorScheme.onSurfaceVariant` at every call
  /// site.
  final bool muted;

  final TextAlign? align;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      textAlign: align,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: AppTypography.scale(v, theme.textTheme).copyWith(
        color: color ??
            (muted ? theme.colorScheme.onSurfaceVariant : null),
      ),
    );
  }
}

/// A small label in a tinted capsule. Neutral by default.
class AppChip extends StatelessWidget {
  const AppChip(this.label, {super.key, this.icon, this.tone});

  final String label;
  final IconData? icon;
  final StatusTone? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolved = tone ??
        StatusTone(
          foreground: theme.colorScheme.onSurfaceVariant,
          background: theme.colorScheme.surfaceContainerHighest,
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: resolved.background,
        borderRadius: BorderRadius.circular(AppRadii.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: resolved.foreground),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: AppTypography.scale(TextVariant.label, theme.textTheme)
                .copyWith(color: resolved.foreground),
          ),
        ],
      ),
    );
  }
}

/// A chip for one of the twelve statuses, with its word in it.
///
/// [label] overrides the default wording where a screen needs to be more
/// specific — "Not graded" rather than "Not reviewed" on a biomarker, because
/// what is withheld there is the grading and not the value.
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.label, this.icon});

  final AppStatus status;
  final String? label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => AppChip(
        label ?? status.label,
        icon: icon,
        tone: status.tone(Theme.of(context).brightness),
      );
}
