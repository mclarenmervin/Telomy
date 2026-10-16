import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/vocabulary/vocabulary.dart';
import '../../patient_care/models/patient_care.dart';
import '../../patient_care/providers/patient_care_provider.dart';
import '../models/therapy_catalogue.dart';
import '../models/therapy_session.dart';
import '../providers/therapy_provider.dart';
import '../widgets/therapy_checkin_sheet.dart';
import 'therapy_catalogue_screen.dart';
import 'therapy_detail_screen.dart';
import 'therapy_plan_screen.dart';
import 'therapy_session_screen.dart';

class TherapyCatalogueRouteScreen extends ConsumerStatefulWidget {
  const TherapyCatalogueRouteScreen({super.key});

  @override
  ConsumerState<TherapyCatalogueRouteScreen> createState() =>
      _TherapyCatalogueRouteScreenState();
}

class _TherapyCatalogueRouteScreenState
    extends ConsumerState<TherapyCatalogueRouteScreen> {
  String? selectedCentreId;

  @override
  Widget build(BuildContext context) {
    final catalogue = ref.watch(therapyCatalogueProvider);
    final care = ref.watch(patientCareProvider);
    if (catalogue.isLoading || care.isLoading) {
      return const Scaffold(
        body: SafeArea(child: Loading('Loading therapies…')),
      );
    }
    if (catalogue.hasError || care.hasError) {
      return const Scaffold(
        body: SafeArea(
          child: Empty(
            title: 'Therapies unavailable',
            body: 'The catalogue or your care centres could not be loaded.',
          ),
        ),
      );
    }
    final centres = care.requireValue.centres;
    final effectiveCentre = selectedCentreId ?? centres.firstOrNull?.id;
    final offerings = effectiveCentre == null
        ? const AsyncData<List<TherapyOffering>>([])
        : ref.watch(therapyOfferingsProvider(effectiveCentre));
    return Scaffold(
      appBar: AppBar(title: const Text('Explore therapies')),
      body: TherapyCatalogueScreen(
        showTitle: false,
        initialItems: catalogue.requireValue,
        initialOfferings: offerings.asData?.value ?? const [],
        centreNames: {for (final centre in centres) centre.id: centre.name},
        selectedCentreId: effectiveCentre,
        onCentreChanged: (value) => setState(() => selectedCentreId = value),
      ),
    );
  }
}

class TherapyDetailRouteScreen extends ConsumerWidget {
  const TherapyDetailRouteScreen({
    super.key,
    required this.catalogueId,
    this.item,
  });
  final String catalogueId;
  final TherapyCatalogueItem? item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogue = item == null ? ref.watch(therapyCatalogueProvider) : null;
    if (item == null && catalogue!.isLoading) {
      return const Scaffold(body: SafeArea(child: Loading('Loading therapy…')));
    }
    final resolved =
        item ??
        catalogue!.asData?.value
            .where((row) => row.id == catalogueId)
            .firstOrNull;
    if (resolved == null) {
      return const Scaffold(
        body: SafeArea(
          child: Empty(
            title: 'Therapy unavailable',
            body: 'Return to the catalogue and choose a published therapy.',
          ),
        ),
      );
    }
    return TherapyDetailScreen(
      item: resolved,
      onPropose: () => _propose(context, ref, resolved),
    );
  }

  Future<void> _propose(
    BuildContext context,
    WidgetRef ref,
    TherapyCatalogueItem item,
  ) async {
    try {
      final care = await ref.read(patientCareProvider.future);
      if (!context.mounted) return;
      final centreId = await _chooseCentre(context, care.centres);
      if (centreId == null || !context.mounted) return;
      final plan = await ref.read(therapyRepositoryProvider).proposePlan(
        centreId,
        [
          {
            'catalogue_id': item.id,
            'modality_id': item.slug,
            'frequency': const {'sessions_per_week': 1},
            'prescribed_dose': _initialDose(item.doseSchema),
          },
        ],
      );
      ref.invalidate(therapyPlansProvider);
      if (context.mounted) context.go('/therapies/plans/${plan.id}');
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The proposal could not be created. Check your care centre and try again.',
            ),
          ),
        );
      }
    }
  }
}

Future<String?> _chooseCentre(
  BuildContext context,
  List<PatientCentre> centres,
) async {
  if (centres.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Join a care centre before proposing a therapy plan.'),
      ),
    );
    return null;
  }
  if (centres.length == 1) return centres.single.id;
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('Choose a care centre'),
      children: [
        for (final centre in centres)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, centre.id),
            child: Text(centre.name),
          ),
      ],
    ),
  );
}

Map<String, dynamic> _initialDose(Map<String, dynamic> schema) => {
  for (final entry in schema.entries)
    if ((entry.value as Map?)?['optional'] != true)
      entry.key:
          (entry.value as Map?)?['minimum'] ??
          ((entry.value as Map?)?['type'] == 'string' ? 'standard' : 1),
};

class TherapyPlanRouteScreen extends ConsumerWidget {
  const TherapyPlanRouteScreen({super.key, required this.planId});
  final String planId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plans = ref.watch(therapyPlansProvider);
    if (plans.isLoading) {
      return const Scaffold(body: SafeArea(child: Loading('Loading plan…')));
    }
    final plan = plans.asData?.value
        .where((row) => row.id == planId)
        .firstOrNull;
    if (plan == null) {
      return const Scaffold(
        body: SafeArea(
          child: Empty(
            title: 'Plan unavailable',
            body: 'This plan is no longer available.',
          ),
        ),
      );
    }
    final offerings = ref.watch(therapyOfferingsProvider(plan.centreId));
    final byCatalogue = {
      for (final offering
          in offerings.asData?.value ?? const <TherapyOffering>[])
        offering.catalogueId: offering.id,
    };
    return TherapyPlanScreen(
      plan: plan,
      viewer: TherapyPlanViewer.patient,
      offeringIdsByCatalogue: byCatalogue,
      onBook: (itemId, offeringId) async {
        try {
          final session = await ref
              .read(therapyRepositoryProvider)
              .book(
                planItemId: itemId,
                offeringId: offeringId,
                idempotencyKey:
                    'mobile-$itemId-${DateTime.now().microsecondsSinceEpoch}',
              );
          ref.invalidate(therapySessionsProvider);
          if (context.mounted) {
            context.go('/therapies/sessions/${session.id}');
          }
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'This item could not be booked. Review its current safety state and try again.',
                ),
              ),
            );
          }
        }
      },
    );
  }
}

class TherapySessionRouteScreen extends ConsumerWidget {
  const TherapySessionRouteScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(therapySessionsProvider);
    if (sessions.isLoading) {
      return const Scaffold(body: SafeArea(child: Loading('Loading session…')));
    }
    final session = sessions.asData?.value
        .where((row) => row.id == sessionId)
        .firstOrNull;
    if (session == null) {
      return const Scaffold(
        body: SafeArea(
          child: Empty(
            title: 'Session unavailable',
            body: 'This session is no longer available.',
          ),
        ),
      );
    }
    return TherapySessionScreen(
      session: session,
      onStart: session.status == 'scheduled'
          ? () => _start(context, ref)
          : null,
      onFinish: session.status == 'started'
          ? () => _finish(context, ref, session)
          : null,
      onCheckin: session.status == 'completed'
          ? () => _checkin(context, ref)
          : null,
    );
  }

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(therapyRepositoryProvider).start(sessionId);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The session did not start. Its safety state has been refreshed.',
            ),
          ),
        );
      }
    } finally {
      ref.invalidate(therapySessionsProvider);
    }
  }

  Future<void> _finish(
    BuildContext context,
    WidgetRef ref,
    TherapySession session,
  ) async {
    final controller = TextEditingController(
      text: session.prescribedDose['duration_minutes']?.toString() ?? '',
    );
    final minutes = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Record delivered dose'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Minutes delivered'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, int.tryParse(controller.text)),
            child: const Text('Complete session'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (minutes == null) return;
    try {
      await ref.read(therapyRepositoryProvider).finish(sessionId, {
        'duration_minutes': minutes,
      });
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The delivered dose could not be saved. Try again.'),
          ),
        );
      }
    } finally {
      ref.invalidate(therapySessionsProvider);
    }
  }

  Future<void> _checkin(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => TherapyCheckinSheet(
        questions: const [
          TherapyCheckinQuestion(
            code: 'perceived_effect',
            prompt: 'How did you feel immediately afterwards?',
          ),
          TherapyCheckinQuestion(
            code: 'tolerability',
            prompt: 'Was the session tolerable?',
          ),
        ],
        onSubmit: (answers) async {
          try {
            await ref
                .read(therapyRepositoryProvider)
                .checkin(sessionId, answers);
            if (sheetContext.mounted) Navigator.pop(sheetContext);
          } catch (_) {
            if (sheetContext.mounted) {
              ScaffoldMessenger.of(sheetContext).showSnackBar(
                const SnackBar(
                  content: Text('The check-in could not be saved. Try again.'),
                ),
              );
            }
          }
        },
      ),
    );
  }
}
