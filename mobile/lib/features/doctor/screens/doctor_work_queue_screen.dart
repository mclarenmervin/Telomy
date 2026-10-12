import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/doctor_models.dart';
import '../providers/doctor_provider.dart';
import '../widgets/work_queue_segment.dart';
import '../widgets/clinical_decision_sheet.dart';

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
                ? 'This segment opens in a later clinical phase.'
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
