import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/doctor_provider.dart';

class DoctorProfileScreen extends ConsumerWidget {
  const DoctorProfileScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(doctorProfileProvider);
    return state.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => const Center(child: Text('Doctor profile unavailable')),
      data: (profile) {
        final expiry = DateTime.tryParse(
          profile['licence_expires_at']?.toString() ?? '',
        );
        final soon =
            expiry != null && expiry.difference(DateTime.now()).inDays <= 60;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Doctor profile',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            ListTile(
              title: const Text('Verification'),
              subtitle: Text(
                profile['verification_status']?.toString() ?? 'pending',
              ),
            ),
            ListTile(
              title: const Text('Registration'),
              subtitle: Text(
                profile['registration_number']?.toString() ?? 'Not recorded',
              ),
            ),
            if (soon)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.warning_amber),
                  title: Text('Licence expires within 60 days'),
                ),
              ),
          ],
        );
      },
    );
  }
}
