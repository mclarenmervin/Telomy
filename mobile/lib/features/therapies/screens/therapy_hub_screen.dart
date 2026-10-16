import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/vocabulary.dart';
import '../models/therapy_plan.dart';
import '../models/therapy_session.dart';
import '../providers/therapy_provider.dart';
import '../widgets/therapy_effects_section.dart';

class TherapyHubScreen extends ConsumerWidget {
  const TherapyHubScreen({
    super.key,
    this.initialPlans,
    this.initialSessions,
    this.showEffects = true,
  });

  final List<TherapyPlan>? initialPlans;
  final List<TherapySession>? initialSessions;
  final bool showEffects;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plans = initialPlans == null ? ref.watch(therapyPlansProvider) : null;
    final sessions = initialSessions == null
        ? ref.watch(therapySessionsProvider)
        : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Therapy')),
      body: AppScreen(
        children: [
          AppCard(
            tone: CardTone.teal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.health_and_safety_outlined, size: 32),
                const SizedBox(height: AppSpacing.sm),
                const T(
                  'Plan first. Check safety every time.',
                  v: TextVariant.h2,
                ),
                const SizedBox(height: AppSpacing.xs),
                const T(
                  'Explore centre therapies, propose a plan, and follow the version your doctor signed.',
                  muted: true,
                ),
                const SizedBox(height: AppSpacing.md),
                FilledButton.icon(
                  onPressed: () => context.push('/therapies/catalogue'),
                  icon: const Icon(Icons.explore_outlined),
                  label: const Text('Explore therapies'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Section(
            title: 'My plans',
            children: _plans(context, initialPlans, plans),
          ),
          const SizedBox(height: AppSpacing.lg),
          Section(
            title: 'Sessions',
            children: _sessions(context, initialSessions, sessions),
          ),
          if (showEffects) ...[
            const SizedBox(height: AppSpacing.lg),
            const TherapyEffectsSection(),
          ],
        ],
      ),
    );
  }

  List<Widget> _plans(
    BuildContext context,
    List<TherapyPlan>? seeded,
    AsyncValue<List<TherapyPlan>>? value,
  ) {
    if (seeded == null && value!.isLoading) {
      return [const Loading('Loading plans…')];
    }
    if (seeded == null && value!.hasError) {
      return const [
        Empty(title: 'Plans unavailable', body: 'Try again shortly.'),
      ];
    }
    final items = seeded ?? value!.requireValue;
    if (items.isEmpty) {
      return const [
        Empty(
          title: 'No therapy plan yet',
          body: 'Explore the catalogue to propose the first item.',
          tone: EmptyTone.waiting,
        ),
      ];
    }
    return [
      for (final plan in items)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            plan.signed
                ? Icons.verified_outlined
                : Icons.pending_actions_outlined,
          ),
          title: Text('Plan v${plan.version}'),
          subtitle: Text(
            plan.signed ? 'Signed by your doctor' : 'Awaiting doctor review',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/therapies/plans/${plan.id}'),
        ),
    ];
  }

  List<Widget> _sessions(
    BuildContext context,
    List<TherapySession>? seeded,
    AsyncValue<List<TherapySession>>? value,
  ) {
    if (seeded == null && value!.isLoading) {
      return [const Loading('Loading sessions…')];
    }
    if (seeded == null && value!.hasError) {
      return const [
        Empty(title: 'Sessions unavailable', body: 'Try again shortly.'),
      ];
    }
    final items = seeded ?? value!.requireValue;
    if (items.isEmpty) {
      return const [
        Empty(
          title: 'No sessions booked',
          body: 'A signed plan can be booked when a centre offers it.',
          tone: EmptyTone.waiting,
        ),
      ];
    }
    return [
      for (final session in items)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event_available_outlined),
          title: Text(_sessionLabel(session.status)),
          subtitle: Text(
            'Prescribed: ${therapyDoseText(session.prescribedDose)}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/therapies/sessions/${session.id}'),
        ),
    ];
  }
}

String _sessionLabel(String status) => switch (status) {
  'scheduled' => 'Scheduled session',
  'started' => 'Session in progress',
  'completed' => 'Completed session',
  'refused' => 'Session stopped for safety',
  'cancelled' => 'Cancelled session',
  _ => 'Therapy session',
};
