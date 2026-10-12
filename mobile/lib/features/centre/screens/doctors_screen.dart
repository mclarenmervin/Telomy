import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/centre_provider.dart';
import 'centre_dashboard_screen.dart';

class DoctorsScreen extends ConsumerWidget {
  const DoctorsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = activeCentre(ref);
    if (id == null) return const Center(child: Text('No active centre'));
    final state = ref.watch(centreDoctorsProvider(id));
    return state.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => const Center(child: Text('Doctors unavailable')),
      data: (items) => ListView(
        children: [
          const ListTile(title: Text('Doctors')),
          if (items.isEmpty)
            const ListTile(title: Text('No doctors yet'))
          else
            for (final item in items)
              ListTile(title: Text(item.name), subtitle: Text(item.status)),
        ],
      ),
    );
  }
}
