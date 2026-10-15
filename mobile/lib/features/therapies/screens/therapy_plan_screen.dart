import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/vocabulary.dart';
import '../models/therapy_plan.dart';
import '../widgets/safety_refusal_card.dart';

enum TherapyPlanViewer { patient, doctor, centre }

class TherapyPlanScreen extends StatelessWidget {
  const TherapyPlanScreen({super.key, required this.plan, required this.viewer, this.onSign});
  final TherapyPlan plan;
  final TherapyPlanViewer viewer;
  final Future<void> Function(String note)? onSign;

  @override Widget build(BuildContext context) {
    final included = plan.items.where((item) => !item.excludedForSafety).toList();
    final excluded = plan.items.where((item) => item.excludedForSafety).toList();
    return Scaffold(
      appBar: AppBar(title: Text('Therapy plan v${plan.version}')),
      body: AppScreen(children: [
        T(plan.signed ? 'Signed by your doctor' : 'Awaiting doctor review', v: TextVariant.h3),
        const SizedBox(height: AppSpacing.lg),
        Section(title: 'In this plan', children: [for (final item in included) _PlanItem(item: item)]),
        if (excluded.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          for (final item in excluded) Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: SafetyRefusalCard(explanations: [item.safetyExplanation ?? '${item.name} is not eligible right now.']),
          ),
        ],
        if (viewer == TherapyPlanViewer.doctor && !plan.signed) ...[
          const SizedBox(height: AppSpacing.lg),
          FilledButton(onPressed: onSign == null ? null : () => _reviewAndSign(context), child: const Text('Review and sign')),
        ],
        if (viewer == TherapyPlanViewer.centre) ...[
          const SizedBox(height: AppSpacing.lg),
          const T('Operational view only', v: TextVariant.h3),
          const T('Centre staff can schedule eligible signed items, but cannot change clinical content.', muted: true),
        ],
      ]),
    );
  }

  Future<void> _reviewAndSign(BuildContext context) async {
    final controller = TextEditingController();
    final note = await showDialog<String>(context: context, builder: (dialogContext) => AlertDialog(
      title: const Text('Sign therapy plan'),
      content: TextField(controller: controller, autofocus: true, maxLines: 3,
        decoration: const InputDecoration(labelText: 'Clinical review note')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
        FilledButton(onPressed: () {
          if (controller.text.trim().isNotEmpty) Navigator.pop(dialogContext, controller.text.trim());
        }, child: const Text('Sign plan')),
      ],
    ));
    controller.dispose();
    if (note != null && context.mounted) await onSign!(note);
  }
}

class _PlanItem extends StatelessWidget {
  const _PlanItem({required this.item});
  final TherapyPlanItem item;
  @override Widget build(BuildContext context) => AppCard(tone: CardTone.copper, child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [T(item.name, v: TextVariant.h3), const SizedBox(height: AppSpacing.xxs), T('Prescribed: ${item.prescribedDose['duration_minutes'] ?? '—'} minutes', muted: true)],
  ));
}
