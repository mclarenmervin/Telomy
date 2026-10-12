import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/centre_provider.dart';
import 'centre_dashboard_screen.dart';

class PatientsScreen extends ConsumerWidget {
  const PatientsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = activeCentre(ref);
    if (id == null) return const Center(child: Text('No active centre'));
    final state = ref.watch(centrePatientsProvider(id));
    return state.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => const Center(child: Text('Patients unavailable')),
      data: (items) => ListView(
        children: [
          const ListTile(title: Text('Patients')),
          if (items.isEmpty)
            const ListTile(title: Text('No patients yet'))
          else
            for (final item in items)
              ListTile(title: Text(item.name), subtitle: Text(item.status)),
        ],
      ),
    );
  }
}
