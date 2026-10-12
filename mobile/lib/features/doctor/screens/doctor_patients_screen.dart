import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/doctor_models.dart';
import '../providers/doctor_provider.dart';

class DoctorPatientsScreen extends ConsumerWidget {
  const DoctorPatientsScreen({super.key, this.initial});
  final List<DoctorPatient>? initial;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (initial != null) return _list(context, initial!, null);
    final id =
        ref.watch(selectedDoctorCentreProvider) ??
        ref.watch(doctorCentresProvider).asData?.value.firstOrNull?.id;
    if (id == null) return const Center(child: Text('No active centre'));
    final state = ref.watch(doctorPatientsProvider(id));
    return state.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => const Center(child: Text('Patients unavailable')),
      data: (items) => _list(context, items, id),
    );
  }

  Widget _list(
    BuildContext context,
    List<DoctorPatient> items,
    String? centreId,
  ) => Material(
    child: items.isEmpty
        ? const Center(child: Text('No patients assigned'))
        : ListView(
            children: [
              for (final p in items)
                ListTile(
                  title: Text(p.name),
                  subtitle: Text(
                    p.assignment['is_primary'] == true
                        ? 'Primary Doctor'
                        : 'Assigned Doctor',
                  ),
                  onTap: centreId == null
                      ? null
                      : () =>
                            context.push('/doctor/$centreId/patients/${p.id}'),
                ),
            ],
          ),
  );
}
