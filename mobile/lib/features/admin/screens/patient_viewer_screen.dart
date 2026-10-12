import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/admin_provider.dart';

class PatientViewerScreen extends ConsumerWidget {
  const PatientViewerScreen({
    super.key,
    required this.patientId,
    this.initialRecord,
  });
  final String patientId;
  final Map<String, dynamic>? initialRecord;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initial = initialRecord;
    if (initial != null) return _body(context, initial);
    final state = ref.watch(adminPatientRecordProvider(patientId));
    return state.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, _) => const Scaffold(
        body: Center(child: Text('Clinical record unavailable')),
      ),
      data: (record) => _body(context, record),
    );
  }

  Widget _body(BuildContext context, Map<String, dynamic> record) => Scaffold(
    appBar: AppBar(title: const Text('Read-only clinical record')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Read-only clinical record'),
        const Text(
          'Super Admin access is audited. Clinical content cannot be edited or signed here.',
        ),
        const SizedBox(height: 16),
        Text('Drafts: ${(record['drafts'] as List? ?? const []).length}'),
        Text(
          'Monthly reports: ${(record['monthly_reports'] as List? ?? const []).length}',
        ),
      ],
    ),
  );
}
