import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/vocabulary.dart';

/// A surface the role spine routes to and a later phase fills.
///
/// Not a stub, and the difference matters. The doctor and centre shells exist
/// in F9 so that the role spine can be verified for all four roles — a
/// redirect that only two roles exercise is a redirect with two untested
/// branches — and so that F10 and F11 fill screens rather than inventing
/// navigation. What they must not do meanwhile is read as a broken product to
/// anybody who signs in, which is why this says what will be here, what is
/// already built behind it, and when.
///
/// It uses [Empty] with [EmptyTone.waiting] for the same reason every other
/// screen does: an empty state that says what will appear here and when is a
/// different thing from a blank page.
class ComingInPhaseScreen extends StatelessWidget {
  const ComingInPhaseScreen({
    super.key,
    required this.title,
    required this.phase,
    required this.what,
    required this.alreadyBuilt,
  });

  final String title;

  /// Named, because "coming soon" is the sentence that stops being true
  /// quietly. A phase number is checkable against the programme document.
  final String phase;

  final String what;

  /// What already exists underneath. The doctor's queue, the signature
  /// machinery and the delivery gate are all shipped and have simply never had
  /// an interface, and somebody looking at this screen should know that rather
  /// than assume nothing has been done.
  final String alreadyBuilt;

  @override
  Widget build(BuildContext context) => AppScreen(
        title: title,
        children: [
          Empty(
            key: const Key('coming-in-phase'),
            title: '$phase builds this',
            body: what,
            tone: EmptyTone.waiting,
          ),
          const SizedBox(height: AppSpacing.xs),
          AppCard(
            tone: CardTone.teal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const T('What is already behind it', v: TextVariant.h3),
                const SizedBox(height: AppSpacing.xxs),
                T(alreadyBuilt, v: TextVariant.small, muted: true),
              ],
            ),
          ),
        ],
      );
}
