import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../auth/providers/auth_provider.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../health/models/health_measurement.dart';
import '../../devices/providers/ring_provider.dart';
import '../../../core/widgets/async_action.dart';
import 'profile_editor.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).asData?.value;
    final state = ref.watch(wellnessProvider);
    final data = state.asData?.value;
    final name = data?.profile['fullName'];
    final weights =
        data?.measurements
            .where((m) => m.measurementType == MeasurementType.weight)
            .toList() ??
        [];
    weights.sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    final height = double.tryParse(data?.profile['height'] ?? '');
    final bmi = height != null && height > 0 && weights.isNotEmpty
        ? weights.last.value / ((height / 100) * (height / 100))
        : null;
    final dob = DateTime.tryParse(data?.profile['dob'] ?? '');
    final now = DateTime.now();
    final age = dob == null
        ? null
        : now.year -
              dob.year -
              (now.month < dob.month ||
                      now.month == dob.month && now.day < dob.day
                  ? 1
                  : 0);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('You', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 24),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.all(20),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(
                'assets/branding/telomy-icon.png',
                width: 48,
                height: 48,
              ),
            ),
            title: Text(
              name?.isNotEmpty == true ? name! : user?.fullName ?? '',
            ),
            subtitle: Text(user?.email ?? ''),
          ),
        ),
        const SizedBox(height: 20),
        if (state.isLoading) const LinearProgressIndicator(),
        if (state.hasError)
          TextButton(
            onPressed: () => ref.invalidate(wellnessProvider),
            child: const Text('Unable to load profile. Retry'),
          ),
        if (age != null || bmi != null)
          Text(
            '${age == null ? '' : 'Age $age'}  ${bmi == null ? '' : 'BMI ${bmi.toStringAsFixed(1)}'}',
          ),
        FilledButton.icon(
          onPressed: data == null
              ? null
              : () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const ProfileEditor(),
                  ),
                ),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Edit profile & goals'),
        ),
        const SizedBox(height: 24),
        Text('Your vault', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        for (final item in const {
          'timeline': 'Life events & daily logs',
          'health': 'Health readings',
          'vitals': 'Heart & vital metrics',
          'sleep': 'Sleep',
          'readiness': 'Recovery & readiness',
          'stress': 'Stress & breathing',
          'activity': 'Activity',
          'body': 'Body composition',
          'calculators': 'Health calculators',
          'labs': 'Lab results',
          'longiscore': 'LongiScore',
          'biological-age': 'Biological age',
          'correlations': 'Health correlations',
          'coach': 'Daily coach',
          'medications': 'Medications',
          'marketplace': 'Wellness marketplace',
          'consultations': 'Consultations',
          'community': 'Community',
          'reports': 'Reports',
          'fitness': 'Fitness & nutrition',
          'devices': 'Wearables',
          'add-ring': 'Add ring',
          'therapy': 'Therapy',
          'environment': 'Environment',
          'genetics': 'Genetics records',
          'ai-copilot': 'Wellness insights',
          'settings': 'Settings & privacy',
          'notifications-privacy': 'Notifications & data controls',
        }.entries)
          ListTile(
            title: Text(item.value),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/${item.key}'),
          ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: () => runAction(context, () async {
            await ref.read(ringProvider.notifier).disconnect();
            await ref.read(authProvider.notifier).logout();
          }),
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}
