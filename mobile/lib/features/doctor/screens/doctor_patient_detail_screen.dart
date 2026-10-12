import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/doctor_models.dart';
import '../providers/doctor_provider.dart';

class DoctorPatientDetailScreen extends ConsumerWidget {
  const DoctorPatientDetailScreen({
    super.key,
    required this.centreId,
    required this.patientId,
  });
  final String centreId, patientId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(
      doctorPatientProvider(DoctorPatientKey(centreId, patientId)),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Patient detail')),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('Patient unavailable')),
        data: (p) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              p['full_name']?.toString() ?? 'Patient',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const Text(
              'Evidence and provenance are shown with each clinical summary.',
            ),
            FilledButton(
              onPressed: () => _note(context, ref),
              child: const Text('Add note'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _note(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController();
    final body = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: c,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Clinical note'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, c.text),
              child: const Text('Save note'),
            ),
          ],
        ),
      ),
    );
    if (body != null && body.trim().isNotEmpty) {
      await ref
          .read(doctorRepositoryProvider)
          .addNote(centreId: centreId, patientId: patientId, body: body.trim());
    }
  }
}
