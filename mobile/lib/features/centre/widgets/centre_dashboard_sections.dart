import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/surfaces.dart';
import '../models/centre_operations.dart';

class CentreDashboardSections extends StatelessWidget {
  const CentreDashboardSections({super.key, required this.dashboard});
  final CentreDashboard dashboard;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Section(
        title: "Today's bookings",
        children: dashboard.todayBookings.isEmpty
            ? const [Text('No bookings today')]
            : [
                for (final booking in dashboard.todayBookings)
                  _BookingRow(booking),
              ],
      ),
      const SizedBox(height: AppSpacing.lg),
      Section(
        title: 'Follow-up recommended',
        blurb:
            'Operational prompts only. A doctor decides the clinical response.',
        children: dashboard.membersAtRisk.isEmpty
            ? const [Text('No members currently need follow-up')]
            : [
                for (final member in dashboard.membersAtRisk)
                  _FollowUpRow(member),
              ],
      ),
      const SizedBox(height: AppSpacing.lg),
      Section(
        title: 'Not seen in 30 days',
        children: dashboard.members.notSeen30Days.isEmpty
            ? const [
                Text('Every consented member has a recent completed visit'),
              ]
            : [
                for (final id in dashboard.members.notSeen30Days)
                  AppRow(label: 'Member', value: id),
              ],
      ),
    ],
  );
}

class CentreUtilisationSection extends StatelessWidget {
  const CentreUtilisationSection({super.key, required this.items});
  final List<ServiceUtilisation> items;

  @override
  Widget build(BuildContext context) => Section(
    title: 'Service utilisation',
    blurb:
        'Utilisation uses configured room capacity, not staff or device availability.',
    children: items.isEmpty
        ? const [Text('No configured service capacity for this month')]
        : [
            for (final item in items)
              AppRow(
                label: item.serviceName,
                value: item.rate == null
                    ? '—'
                    : '${(item.rate! * 100).round()}%',
              ),
          ],
  );
}

class _BookingRow extends StatelessWidget {
  const _BookingRow(this.booking);
  final CentreBooking booking;

  @override
  Widget build(BuildContext context) => AppCard(
    child: Row(
      children: [
        SizedBox(
          width: 54,
          child: Text(DateFormat.Hm().format(booking.scheduledStart.toLocal())),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(booking.serviceNameSnapshot),
              Text(
                booking.status.replaceAll('_', ' '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _FollowUpRow extends StatelessWidget {
  const _FollowUpRow(this.member);
  final FollowUpMember member;

  @override
  Widget build(BuildContext context) => AppCard(
    tone: CardTone.copper,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          member.displayName,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(member.action),
        Text(member.date, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}
