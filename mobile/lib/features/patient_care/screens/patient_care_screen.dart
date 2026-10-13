import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/patient_care.dart';
import '../providers/patient_care_provider.dart';

class PatientCareScreen extends ConsumerWidget {
  const PatientCareScreen({super.key, this.initial});
  final PatientCare? initial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (initial case final care?) return _CareList(care: care);
    return ref
        .watch(patientCareProvider)
        .when(
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (_, _) => Scaffold(
            appBar: AppBar(title: const Text('Centres & care team')),
            body: Center(
              child: TextButton(
                onPressed: () => ref.invalidate(patientCareProvider),
                child: const Text('Unable to load care team. Retry'),
              ),
            ),
          ),
          data: (care) => Scaffold(
            appBar: AppBar(title: const Text('Centres & care team')),
            body: _CareList(
              care: care,
              onConsent: (centreId, granted) => ref
                  .read(patientCareActionsProvider)
                  .setConsent(centreId, granted),
            ),
          ),
        );
  }
}

class _CareList extends StatelessWidget {
  const _CareList({required this.care, this.onConsent});
  final PatientCare care;
  final Future<void> Function(String, bool)? onConsent;

  @override
  Widget build(BuildContext context) {
    if (care.centres.isEmpty) {
      return const Center(child: Text('You do not belong to a centre yet.'));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final centre in care.centres)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    centre.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  if (centre.doctors.isEmpty) const Text('No doctor assigned'),
                  for (final doctor in centre.doctors)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.medical_services_outlined),
                      title: Text(doctor.name),
                      subtitle: Text(
                        doctor.isPrimary
                            ? 'Primary doctor'
                            : 'Additional doctor',
                      ),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Allow centre clinical access'),
                    subtitle: Text(_consentDescription(centre)),
                    value: centre.consentActive,
                    onChanged: onConsent == null
                        ? null
                        : (value) async {
                            try {
                              await onConsent!(centre.id, value);
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Consent choice was not saved.',
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

String _consentDescription(PatientCentre centre) {
  final expiry = centre.consentExpiresAt;
  if (centre.consentActive && expiry != null) {
    return 'Clinical access expires on ${_shortDate(expiry)}. '
        'You can revoke it at any time.';
  }
  if (centre.consentExpired && expiry != null) {
    return 'Clinical access expired on ${_shortDate(expiry)}. '
        'Turn it on to renew for one year.';
  }
  return 'Centre owners can view your clinical record only while this is on. '
      'New consent lasts one year.';
}

String _shortDate(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final date = value.toLocal();
  return '${date.day} ${months[date.month - 1]} ${date.year}';
}
