import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/centre_provider.dart';

class CentreProfileScreen extends ConsumerWidget {
  const CentreProfileScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final centres = ref.watch(myCentresProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Centre profile',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        ...centres.when(
          loading: () => [const LinearProgressIndicator()],
          error: (_, _) => [const Text('Centre profile unavailable')],
          data: (items) => [
            DropdownButton<String>(
              value: ref.watch(selectedCentreProvider) ?? items.firstOrNull?.id,
              isExpanded: true,
              hint: const Text('Select a centre'),
              items: [
                for (final item in items)
                  DropdownMenuItem(value: item.id, child: Text(item.name)),
              ],
              onChanged: (value) {
                if (value != null) {
                  ref.read(selectedCentreProvider.notifier).select(value);
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}
