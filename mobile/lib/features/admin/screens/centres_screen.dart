import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/admin_provider.dart';

class CentresScreen extends ConsumerWidget {
  const CentresScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final centres = ref.watch(centresProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Centres')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context, ref),
        label: const Text('Create centre'),
      ),
      body: centres.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('Centres unavailable')),
        data: (items) => items.isEmpty
            ? const Center(child: Text('No centres yet'))
            : ListView(
                children: [
                  for (final centre in items)
                    ListTile(
                      title: Text(centre.name),
                      subtitle: Text(centre.status),
                    ),
                ],
              ),
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create centre'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Centre name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await ref.read(adminRepositoryProvider).createCentre(name);
      ref.invalidate(centresProvider);
    }
  }
}
