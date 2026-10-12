import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import 'prov.dart';
import 'text.dart';

/// The containers.
///
/// **On the names.** The programme says to port the vocabulary by name, and
/// four of these cannot be: `Screen`, `Card`, `Row` and `Chip` would shadow
/// Flutter's own widgets in every file that imported them, which is a trap
/// rather than a convention. Those four take an `App` prefix and the other ten
/// keep the prototype's names exactly.

/// Teal is science; copper is the person.
///
/// A tone is not a status. "This card is about your plan" is a different
/// statement from "this value is out of range", and the moment a tone is used
/// to mean a status there are two colour systems saying overlapping things.
enum CardTone { plain, teal, copper }

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.tone = CardTone.plain,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.onTap,
  });

  final Widget child;
  final CardTone tone;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final colour = switch (tone) {
      CardTone.plain => theme.colorScheme.surface,
      CardTone.teal =>
        dark ? const Color(0xFF14302C) : AppColors.tealSoft,
      CardTone.copper =>
        dark ? const Color(0xFF36261A) : AppColors.copperSoft,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Material(
        color: colour,
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.card),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// A label and a value on one line, which is most of what a Vault is.
class AppRow extends StatelessWidget {
  const AppRow({super.key, required this.label, required this.value, this.trailing});

  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
        child: Row(
          children: [
            Expanded(child: T(label, muted: true)),
            T(value),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.xs),
              trailing!,
            ],
          ],
        ),
      );
}

class SectionAction {
  const SectionAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

/// A title, at most one action, and the things under it.
///
/// One action rather than a row of them, which is the prototype's rule and
/// worth keeping: a section header with three buttons is a section that should
/// have been two sections.
class Section extends StatelessWidget {
  const Section({
    super.key,
    required this.title,
    required this.children,
    this.blurb,
    this.action,
  });

  final String title;
  final List<Widget> children;

  /// The sentence under the title that says what this is and what it is not.
  /// Several of the F8 screens live or die on theirs.
  final String? blurb;

  final SectionAction? action;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: T(title, v: TextVariant.h3)),
              if (action != null)
                TextButton(
                  onPressed: action!.onPressed,
                  child: Text(action!.label),
                ),
            ],
          ),
          if (blurb != null) ...[
            const SizedBox(height: AppSpacing.xxs),
            T(blurb!, v: TextVariant.small, muted: true),
          ],
          const SizedBox(height: AppSpacing.sm),
          ...children,
        ],
      );
}

/// A number, its unit, and where it came from.
///
/// [value] is a String and not a num on purpose: the caller has already
/// decided how many decimal places this number deserves, and a widget that
/// formatted it would be a second opinion about precision. A UV index of 10.2
/// is not 10.
///
/// A null value renders an em dash. It must never render a zero — the phone's
/// health reader returns 0 for an absent field, and that has already
/// manufactured correlations out of missing data once.
class Stat extends StatelessWidget {
  const Stat({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.prov,
    this.status,
  });

  final String label;
  final String? value;
  final String? unit;
  final Prov? prov;
  final Widget? status;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          T(label, v: TextVariant.small, muted: true),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              T(value ?? '—', v: TextVariant.num),
              if (unit != null && value != null) ...[
                const SizedBox(width: AppSpacing.xxs),
                T(unit!, v: TextVariant.small, muted: true),
              ],
              if (status != null) ...[
                const SizedBox(width: AppSpacing.xs),
                status!,
              ],
            ],
          ),
          ?prov,
        ],
      );
}

/// A segmented control over a small set of choices.
class Segmented<Value> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final Map<Value, String> options;
  final Value selected;
  final ValueChanged<Value> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<Value>(
        segments: [
          for (final option in options.entries)
            ButtonSegment(value: option.key, label: Text(option.value)),
        ],
        selected: {selected},
        showSelectedIcon: false,
        onSelectionChanged: (value) => onChanged(value.first),
      );
}

/// A tappable row in a list.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.small),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              vertical: AppSpacing.sm, horizontal: AppSpacing.xxs),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    T(title),
                    if (subtitle != null)
                      T(subtitle!, v: TextVariant.small, muted: true),
                  ],
                ),
              ),
              ?trailing,
              if (onTap != null) ...[
                const SizedBox(width: AppSpacing.xxs),
                Icon(Icons.chevron_right,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ],
            ],
          ),
        ),
      );
}

/// A screen: pull to refresh, a bounded reading width, consistent padding.
///
/// The width bound is why this is a component rather than a convention. On a
/// tablet or in the rail layout at ≥ 760 px, an unbounded column gives
/// 1600-pixel lines of body text that nobody can read, and every screen that
/// forgot to wrap itself in a ConstrainedBox had exactly that.
class AppScreen extends StatelessWidget {
  const AppScreen({
    super.key,
    required this.children,
    this.title,
    this.onRefresh,
    this.maxWidth = 1200,
  });

  final List<Widget> children;
  final String? title;
  final Future<void> Function()? onRefresh;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxxl),
      children: [
        if (title != null) ...[
          T(title!, v: TextVariant.h1),
          const SizedBox(height: AppSpacing.md),
        ],
        ...children,
      ],
    );

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: onRefresh == null
            ? list
            : RefreshIndicator(onRefresh: onRefresh!, child: list),
      ),
    );
  }
}
