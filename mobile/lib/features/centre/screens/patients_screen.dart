import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/surfaces.dart';
import '../models/centre_operations.dart';
import '../models/centre_roster.dart';
import '../providers/centre_provider.dart';
import 'centre_dashboard_screen.dart';

typedef AssignMemberDoctor =
    Future<void> Function(String patientId, String doctorId, bool primary);

class PatientsScreen extends StatelessWidget {
  const PatientsScreen({
    super.key,
    this.initial,
    this.patients = const [],
    this.doctors = const [],
    this.onAssign,
    this.onInvitePatient,
  });

  final List<CentreMember>? initial;
  final List<CentrePerson> patients;
  final List<CentrePerson> doctors;
  final AssignMemberDoctor? onAssign;
  final Future<void> Function(String email)? onInvitePatient;

  @override
  Widget build(BuildContext context) => initial == null
      ? const _MembersLoader()
      : _MembersView(
          members: initial!,
          patients: patients,
          doctors: doctors,
          onAssign: onAssign,
          onInvitePatient: onInvitePatient,
        );
}

class _MembersLoader extends ConsumerWidget {
  const _MembersLoader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final membershipId = activeCentre(ref);
    if (membershipId == null) {
      return const Center(child: Text('No active centre membership'));
    }
    final members = ref.watch(centreMembersProvider(membershipId));
    final patients = ref.watch(centrePatientsProvider(membershipId));
    final doctors = ref.watch(centreDoctorsProvider(membershipId));
    if (members.isLoading || patients.isLoading || doctors.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (members.hasError || patients.hasError || doctors.hasError) {
      return const Center(child: Text('Members are unavailable. Try again.'));
    }
    return _MembersView(
      members: members.requireValue,
      patients: patients.requireValue,
      doctors: doctors.requireValue,
      onAssign: (patientId, doctorId, primary) async {
        await ref
            .read(centreRepositoryProvider)
            .assign(
              membershipId: membershipId,
              patientId: patientId,
              doctorId: doctorId,
              primary: primary,
            );
        ref.invalidate(centreMembersProvider(membershipId));
      },
      onInvitePatient: (email) async {
        await ref
            .read(centreRepositoryProvider)
            .invite(membershipId: membershipId, email: email, role: 'member');
        ref.invalidate(centrePatientsProvider(membershipId));
      },
    );
  }
}

class _MembersView extends StatelessWidget {
  const _MembersView({
    required this.members,
    required this.patients,
    required this.doctors,
    this.onAssign,
    this.onInvitePatient,
  });
  final List<CentreMember> members;
  final List<CentrePerson> patients;
  final List<CentrePerson> doctors;
  final AssignMemberDoctor? onAssign;
  final Future<void> Function(String email)? onInvitePatient;

  @override
  Widget build(BuildContext context) => Material(
    child: ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Text('Members', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          'People with current clinical-care consent. Team roster membership is managed separately.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (members.isEmpty)
          const AppCard(
            child: Text('No members currently share data with this centre.'),
          )
        else
          for (final member in members)
            _MemberCard(member: member, doctors: doctors, onAssign: onAssign),
        const SizedBox(height: AppSpacing.xl),
        Row(
          children: [
            Expanded(
              child: Text(
                'Patient roster',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            if (onInvitePatient != null)
              FilledButton.icon(
                onPressed: () => _invitePatient(context),
                icon: const Icon(Icons.person_add_outlined),
                label: const Text('Invite patient'),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xxs),
        const Text(
          'Operational roster access is separate from clinical-data consent.',
        ),
        const SizedBox(height: AppSpacing.sm),
        if (patients.isEmpty)
          const AppCard(child: Text('No patients have joined this centre yet.'))
        else
          for (final patient in patients)
            AppCard(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(patient.name),
                subtitle: Text(patient.status),
                trailing: doctors.isNotEmpty && onAssign != null
                    ? TextButton(
                        onPressed: () => _assignRosterPatient(context, patient),
                        child: const Text('Assign doctor'),
                      )
                    : null,
              ),
            ),
      ],
    ),
  );

  Future<void> _invitePatient(BuildContext context) async {
    final email = await showDialog<String>(
      context: context,
      builder: (context) => const _InvitePatientDialog(),
    );
    if (email != null && email.contains('@')) await onInvitePatient!(email);
  }

  Future<void> _assignRosterPatient(
    BuildContext context,
    CentrePerson patient,
  ) async {
    var doctorId = doctors.first.id;
    var primary = true;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Assign doctor to ${patient.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final doctor in doctors)
                ListTile(
                  leading: Icon(
                    doctor.id == doctorId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  onTap: () => setDialogState(() => doctorId = doctor.id),
                  title: Text(doctor.name),
                ),
              CheckboxListTile(
                value: primary,
                onChanged: (value) =>
                    setDialogState(() => primary = value ?? true),
                title: const Text('Primary doctor'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save assignment'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) await onAssign!(patient.id, doctorId, primary);
  }
}

class _InvitePatientDialog extends StatefulWidget {
  const _InvitePatientDialog();

  @override
  State<_InvitePatientDialog> createState() => _InvitePatientDialogState();
}

class _InvitePatientDialogState extends State<_InvitePatientDialog> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Invite patient'),
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

class _MemberCard extends StatelessWidget {
  const _MemberCard({
    required this.member,
    required this.doctors,
    this.onAssign,
  });
  final CentreMember member;
  final List<CentrePerson> doctors;
  final AssignMemberDoctor? onAssign;

  @override
  Widget build(BuildContext context) {
    final completed =
        member.bookings
            .where((booking) => booking.status == 'completed')
            .toList()
          ..sort((a, b) => b.scheduledStart.compareTo(a.scheduledStart));
    final upcoming =
        member.bookings
            .where(
              (booking) =>
                  !booking.isTerminal &&
                  booking.scheduledStart.isAfter(DateTime.now()),
            )
            .toList()
          ..sort((a, b) => a.scheduledStart.compareTo(b.scheduledStart));
    final primaryId = member.assignments
        .where((row) => row['is_primary'] == true)
        .map((row) => row['doctor_id']?.toString())
        .firstOrNull;
    final doctorName = doctors
        .where((doctor) => doctor.id == primaryId)
        .map((doctor) => doctor.name)
        .firstOrNull;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            member.displayName,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Last visit: ${completed.isEmpty ? 'Not recorded' : _day(completed.first.scheduledStart)}',
          ),
          Text(
            'Next booking: ${upcoming.isEmpty ? 'None scheduled' : _day(upcoming.first.scheduledStart)}',
          ),
          Text('Assigned doctor: ${doctorName ?? 'Not assigned'}'),
          if (member.riskEvidence.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.copperSoft,
                borderRadius: BorderRadius.circular(AppRadii.small),
              ),
              child: const Text('Suggest a doctor consultation or retest.'),
            ),
          ],
          if (doctors.isNotEmpty && onAssign != null) ...[
            const SizedBox(height: AppSpacing.sm),
            TextButton.icon(
              onPressed: () => _assign(context),
              icon: const Icon(Icons.assignment_ind_outlined),
              label: const Text('Assign doctor'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _assign(BuildContext context) async {
    var doctorId = doctors.first.id;
    var primary = true;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Assign doctor to ${member.displayName}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final doctor in doctors)
                ListTile(
                  leading: Icon(
                    doctor.id == doctorId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  onTap: () => setDialogState(() => doctorId = doctor.id),
                  title: Text(doctor.name),
                ),
              CheckboxListTile(
                value: primary,
                onChanged: (value) =>
                    setDialogState(() => primary = value ?? true),
                title: const Text('Primary doctor'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save assignment'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) await onAssign!(member.id, doctorId, primary);
  }
}

String _day(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
