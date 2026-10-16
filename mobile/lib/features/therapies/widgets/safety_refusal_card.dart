import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';

class SafetyRefusalCard extends StatelessWidget {
  const SafetyRefusalCard({super.key, required this.explanations});
  final List<String> explanations;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      label: 'Therapy left out for safety',
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.errorContainer,
          borderRadius: BorderRadius.circular(AppRadii.card),
          border: Border(left: BorderSide(color: colors.error, width: 5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.shield_outlined, color: colors.onErrorContainer),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Left out for safety',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            for (final reason in explanations)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
                child: Text(
                  reason,
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            const FilledButton(
              onPressed: null,
              child: Text('Booking unavailable'),
            ),
          ],
        ),
      ),
    );
  }
}
