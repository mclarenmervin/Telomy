import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/doctor_models.dart';
import '../providers/doctor_provider.dart';
import '../widgets/centre_selector.dart';

class DoctorTodayScreen extends ConsumerWidget {
  const DoctorTodayScreen({super.key, this.initial});
  final DoctorToday? initial;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (initial != null) return _content(context, initial!);
    final centres = ref.watch(doctorCentresProvider);
    return centres.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) =>
          const Center(child: Text('Doctor workspace unavailable')),
      data: (items) {
        final id =
            ref.watch(selectedDoctorCentreProvider) ?? items.firstOrNull?.id;
        if (id == null) return const Center(child: Text('No active centre'));
        final today = ref.watch(doctorTodayProvider(id));
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            CentreSelector(
              centres: items,
              selectedId: id,
              onSelected: ref
                  .read(selectedDoctorCentreProvider.notifier)
                  .select,
            ),
            ...today.when(
              loading: () => [const LinearProgressIndicator()],
              error: (_, _) => [const Text('Today is unavailable')],
              data: (value) => [_content(context, value)],
            ),
          ],
        );
      },
    );
  }

  Widget _content(BuildContext context, DoctorToday value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Today', style: Theme.of(context).textTheme.headlineSmall),
      Card(
        child: ListTile(
          title: const Text('Assigned patients'),
          trailing: Text('${value.patientCount}'),
        ),
      ),
      Card(
        child: ListTile(
          title: const Text('Work queue'),
          subtitle: Text('${value.pendingWork} items awaiting review'),
        ),
      ),
      Text(
        'Critical escalations',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      Text('${value.criticalEscalations.length}'),
    ],
  );
}
