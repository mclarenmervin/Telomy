import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/centre_provider.dart';
import 'doctors_screen.dart';

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
              value:
                  ref.watch(selectedCentreProvider) ??
                  items.firstOrNull?.membershipId,
              isExpanded: true,
              hint: const Text('Select a centre'),
              items: [
                for (final item in items)
                  DropdownMenuItem(
                    value: item.membershipId,
                    child: Text(item.name),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  ref.read(selectedCentreProvider.notifier).select(value);
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text('Team', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'Invite doctors and review the operational roster. Patient data appears in Members only while consent is current.',
        ),
        const SizedBox(height: 12),
        const SizedBox(height: 360, child: DoctorsScreen()),
      ],
    );
  }
}
