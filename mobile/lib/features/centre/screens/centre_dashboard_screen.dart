import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/centre_provider.dart';

String? activeCentre(WidgetRef ref) =>
    ref.watch(selectedCentreProvider) ??
    ref.watch(myCentresProvider).asData?.value.firstOrNull?.membershipId;

class CentreDashboardScreen extends ConsumerWidget {
  const CentreDashboardScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = activeCentre(ref);
    if (id == null) {
      return const Center(child: Text('No active centre membership'));
    }
    final doctors = ref.watch(centreDoctorsProvider(id));
    final patients = ref.watch(centrePatientsProvider(id));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Centre dashboard',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            title: const Text('Doctors'),
            trailing: Text('${doctors.asData?.value.length ?? '—'}'),
          ),
        ),
        Card(
          child: ListTile(
            title: const Text('Patients'),
            trailing: Text('${patients.asData?.value.length ?? '—'}'),
          ),
        ),
      ],
    );
  }
}
