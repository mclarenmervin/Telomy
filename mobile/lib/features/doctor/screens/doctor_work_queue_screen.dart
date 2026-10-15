import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/doctor_models.dart';
import '../providers/doctor_provider.dart';
import '../widgets/work_queue_segment.dart';
import '../widgets/clinical_decision_sheet.dart';
import '../../therapies/models/therapy_plan.dart';
import '../../therapies/screens/therapy_plan_screen.dart';

class DoctorWorkQueueScreen extends ConsumerWidget {
  const DoctorWorkQueueScreen({super.key, this.initial});
  final DoctorWorkQueue? initial;
  static const labels = {
    'monthly_reports': 'Monthly reports',
    'sync_drafts': 'Sinc drafts',
    'consults': 'Consults',
    'therapy_plans': 'Therapy plans',
    'rx_supplements': 'Rx & supplements',
  };
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (initial != null) return _list(context, ref, initial!, null);
    final id =
        ref.watch(selectedDoctorCentreProvider) ??
        ref.watch(doctorCentresProvider).asData?.value.firstOrNull?.id;
    if (id == null) return const Center(child: Text('No active centre'));
    final state = ref.watch(doctorWorkQueueProvider(id));
    return state.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => const Center(child: Text('Work queue unavailable')),
      data: (queue) => _list(context, ref, queue, id),
    );
  }

  Widget _list(
    BuildContext context,
    WidgetRef ref,
    DoctorWorkQueue queue,
    String? centre,
  ) => Material(
    child: ListView(
      children: [
        for (final e in labels.entries)
          WorkQueueSegment(
            label: e.value,
            items: queue.segments[e.key] ?? const [],
            emptyMessage: e.key == 'therapy_plans' || e.key == 'rx_supplements'
                ? (e.key == 'therapy_plans' ? 'No therapy plans awaiting review' : 'This segment opens in a later clinical phase.')
                : 'No work waiting',
            onOpen: centre == null
                ? null
                : (item) => _open(context, ref, centre, e.key, item),
          ),
      ],
    ),
  );
  void _open(
    BuildContext context,
    WidgetRef ref,
    String centre,
    String segment,
    Map<String, dynamic> item,
  ) {
    if (segment == 'therapy_plans') {
      final plan = TherapyPlan.fromJson(item);
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) => TherapyPlanScreen(
          plan: plan,
          viewer: TherapyPlanViewer.doctor,
          onSign: (note) async {
            await ref.read(doctorRepositoryProvider).signTherapyPlan(
              centreId: centre,
              planId: plan.id,
              note: note,
              contentSha256: plan.contentSha256,
            );
            if (sheetContext.mounted) Navigator.pop(sheetContext);
            ref.invalidate(doctorWorkQueueProvider(centre));
          },
        ),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => ClinicalDecisionSheet(
        onSign: (note) async {
          final repo = ref.read(doctorRepositoryProvider);
          if (segment == 'monthly_reports') {
            await repo.signReport(
              centreId: centre,
              reportId: item['id'].toString(),
              note: note,
              version: item['version'].toString(),
            );
          } else {
            await repo.signDraft(
              centreId: centre,
              draftId: item['id'].toString(),
              note: note,
              version: item['updated_at'].toString(),
            );
          }
          ref.invalidate(doctorWorkQueueProvider(centre));
        },
        onReject: (note) async {
          final repo = ref.read(doctorRepositoryProvider);
          if (segment == 'monthly_reports') {
            await repo.rejectReport(
              centreId: centre,
              reportId: item['id'].toString(),
              note: note,
              version: item['version'].toString(),
            );
          } else {
            await repo.rejectDraft(
              centreId: centre,
              draftId: item['id'].toString(),
              note: note,
              version: item['updated_at'].toString(),
            );
          }
          ref.invalidate(doctorWorkQueueProvider(centre));
        },
      ),
    );
  }
}
