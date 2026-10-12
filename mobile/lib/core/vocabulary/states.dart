import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import 'surfaces.dart';
import 'text.dart';

/// What to do when there is nothing to show.
///
/// Three components that are not polish, and the reason is in the roadmap
/// rather than in taste: three phases from now the therapy tab's commonest
/// state will be "no reliable signal yet", and if `Empty` is a shrug by then
/// it will read as a broken feature. The prototype got this right — its empty
/// states say what will appear here and when, its loaders say what is
/// loading, its errors retry — so this is a port and not an invention.
enum EmptyTone {
  /// Nothing here yet, and something will be.
  waiting,

  /// **A result.** "We tested five patterns and none of them held up" is an
  /// answer, not an absence, and it takes this component because it has no
  /// list to render. It must not look like a failure: no error icon, no
  /// warning colour, and the body carries the finding.
  result,

  /// Nothing here, and nothing will be until the person does something.
  action,
}

class EmptyAction {
  const EmptyAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

/// Never a blank list.
///
/// [title] and [body] are both required. An `Empty` with a title alone is the
/// shrug this exists to prevent: "No sessions" tells somebody nothing, and
/// "Sessions appear here five minutes before the booked slot" tells them when
/// to come back.
class Empty extends StatelessWidget {
  const Empty({
    super.key,
    required this.title,
    required this.body,
    this.tone = EmptyTone.waiting,
    this.actions = const [],
  });

  final String title;
  final String body;
  final EmptyTone tone;
  final List<EmptyAction> actions;

  @override
  Widget build(BuildContext context) {
    final icon = switch (tone) {
      EmptyTone.waiting => Icons.schedule_outlined,
      // A tick, not a warning. The finding is that we looked.
      EmptyTone.result => Icons.check_circle_outline,
      EmptyTone.action => Icons.add_circle_outline,
    };

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: AppSpacing.xs),
              Expanded(child: T(title, v: TextVariant.h3)),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          T(body, muted: true),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final action in actions)
                  FilledButton.tonal(
                    onPressed: action.onPressed,
                    child: Text(action.label),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Says what is loading.
///
/// "Reading your Vault…" rather than a bare spinner. A spinner says the app is
/// busy; this says the app is doing the thing the person asked for, which is
/// the difference between waiting and wondering.
class Loading extends StatelessWidget {
  const Loading(this.what, {super.key});

  final String what;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            T(what, muted: true),
            const SizedBox(height: AppSpacing.xs),
            const LinearProgressIndicator(minHeight: 3),
          ],
        ),
      );
}

/// Something went wrong, and here is the way out.
///
/// [onRetry] is optional because some failures have nothing to retry — an
/// upload the server refused for a reason that will not change — and a
/// "Try again" that cannot work is worse than none.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
              const SizedBox(width: AppSpacing.xs),
              Expanded(child: T(message)),
            ],
          ),
          if (onRetry != null) ...[
            const SizedBox(height: AppSpacing.xs),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ],
      ),
    );
  }
}

/// A brief message over the screen.
///
/// A function rather than a widget, because every caller wants it from an
/// event handler and none of them want to hold state for it.
void showToast(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(SnackBar(
    content: Text(message),
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 3),
  ));
}
