import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/vocabulary.dart';
import '../models/therapy_catalogue.dart';

class TherapyDetailScreen extends StatelessWidget {
  const TherapyDetailScreen({super.key, required this.item});
  final TherapyCatalogueItem item;

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(item.name)),
    body: AppScreen(children: [
      T(item.summary, v: TextVariant.h3),
      const SizedBox(height: AppSpacing.sm), T(item.intendedExperience, muted: true),
      const SizedBox(height: AppSpacing.xl),
      Section(title: 'Safety comes first', blurb: 'Telomy checks these facts again when you book and when the session starts.', children: [
        if (item.contraindicationRuleIds.isEmpty) const T('No hard exclusions are declared for this therapy.')
        else for (final rule in item.contraindicationRuleIds) ListTile(
          contentPadding: EdgeInsets.zero, leading: const Icon(Icons.verified_user_outlined),
          title: Text(safetyFactLabel(rule)),
        ),
      ]),
      const SizedBox(height: AppSpacing.lg),
      FilledButton(onPressed: () {}, child: const Text('Add to a proposed plan')),
    ]),
  );
}
