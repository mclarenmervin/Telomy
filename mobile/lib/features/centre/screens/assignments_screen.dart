import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/centre_provider.dart';
import 'centre_dashboard_screen.dart';

class AssignmentsScreen extends ConsumerStatefulWidget {
  const AssignmentsScreen({super.key});
  @override
  ConsumerState<AssignmentsScreen> createState() => _AssignmentsScreenState();
}

class _AssignmentsScreenState extends ConsumerState<AssignmentsScreen> {
  final patient = TextEditingController();
  final doctor = TextEditingController();
  bool primary = true;
  String? message;
  @override
  void dispose() {
    patient.dispose();
    doctor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('Assign a Doctor', style: Theme.of(context).textTheme.headlineSmall),
      TextField(
        controller: patient,
        decoration: const InputDecoration(labelText: 'Patient ID'),
      ),
      TextField(
        controller: doctor,
        decoration: const InputDecoration(labelText: 'Doctor ID'),
      ),
      SwitchListTile(
        value: primary,
        onChanged: (value) => setState(() => primary = value),
        title: const Text('Primary Doctor'),
      ),
      FilledButton(
        onPressed: () async {
          final id = activeCentre(ref);
          if (id == null) return;
          await ref
              .read(centreRepositoryProvider)
              .assign(
                centreId: id,
                patientId: patient.text.trim(),
                doctorId: doctor.text.trim(),
                primary: primary,
              );
          if (mounted) setState(() => message = 'Assignment saved');
        },
        child: const Text('Assign'),
      ),
      if (message != null) Text(message!),
    ],
  );
}
