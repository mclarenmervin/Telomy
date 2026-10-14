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
    this.doctors = const [],
    this.onAssign,
  });

  final List<CentreMember>? initial;
  final List<CentrePerson> doctors;
  final AssignMemberDoctor? onAssign;

  @override
  Widget build(BuildContext context) => initial == null
      ? const _MembersLoader()
      : _MembersView(members: initial!, doctors: doctors, onAssign: onAssign);
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
    final doctors = ref.watch(centreDoctorsProvider(membershipId));
    if (members.isLoading || doctors.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (members.hasError || doctors.hasError) {
      return const Center(child: Text('Members are unavailable. Try again.'));
    }
    return _MembersView(
      members: members.requireValue,
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
    );
  }
}

class _MembersView extends StatelessWidget {
  const _MembersView({
    required this.members,
    required this.doctors,
    this.onAssign,
  });
  final List<CentreMember> members;
  final List<CentrePerson> doctors;
  final AssignMemberDoctor? onAssign;

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
      ],
    ),
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
