import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/surfaces.dart';
import '../models/centre_roster.dart';
import '../providers/centre_provider.dart';
import 'centre_dashboard_screen.dart';

class DoctorsScreen extends StatelessWidget {
  const DoctorsScreen({super.key, this.initial, this.onInvite});
  final List<CentrePerson>? initial;
  final Future<void> Function(String email)? onInvite;

  @override
  Widget build(BuildContext context) => initial == null
      ? const _DoctorsLoader()
      : DoctorRosterView(doctors: initial!, onInvite: onInvite);
}

class _DoctorsLoader extends ConsumerWidget {
  const _DoctorsLoader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final membershipId = activeCentre(ref);
    if (membershipId == null) {
      return const Center(child: Text('No active centre'));
    }
    return ref
        .watch(centreDoctorsProvider(membershipId))
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => const Center(child: Text('Team roster unavailable')),
          data: (items) => DoctorRosterView(
            doctors: items,
            onInvite: (email) async {
              await ref
                  .read(centreRepositoryProvider)
                  .invite(
                    membershipId: membershipId,
                    email: email,
                    role: 'doctor',
                  );
              ref.invalidate(centreDoctorsProvider(membershipId));
            },
          ),
        );
  }
}

class DoctorRosterView extends StatelessWidget {
  const DoctorRosterView({super.key, required this.doctors, this.onInvite});
  final List<CentrePerson> doctors;
  final Future<void> Function(String email)? onInvite;

  @override
  Widget build(BuildContext context) => Material(
    child: ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Team roster',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            if (onInvite != null)
              FilledButton.icon(
                onPressed: () => _invite(context),
                icon: const Icon(Icons.person_add_outlined),
                label: const Text('Invite doctor'),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xxs),
        const Text(
          'Roster access is separate from a patient’s consent to share clinical data.',
        ),
        const SizedBox(height: AppSpacing.lg),
        if (doctors.isEmpty)
          const AppCard(child: Text('No doctors have joined this centre yet.'))
        else
          for (final doctor in doctors)
            AppCard(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                title: Text(doctor.name),
                subtitle: Text(doctor.status),
              ),
            ),
      ],
    ),
  );

  Future<void> _invite(BuildContext context) async {
    final email = await showDialog<String>(
      context: context,
      builder: (context) => const _InviteDoctorDialog(),
    );
    if (email != null && email.contains('@')) await onInvite!(email);
  }
}

class _InviteDoctorDialog extends StatefulWidget {
  const _InviteDoctorDialog();

  @override
  State<_InviteDoctorDialog> createState() => _InviteDoctorDialogState();
}

class _InviteDoctorDialogState extends State<_InviteDoctorDialog> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Invite doctor'),
    content: TextField(
      controller: controller,
      keyboardType: TextInputType.emailAddress,
      decoration: const InputDecoration(labelText: 'Email'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text.trim()),
        child: const Text('Send invitation'),
      ),
    ],
  );
}
