import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../models/centre_operations.dart';
import '../providers/centre_provider.dart';
import '../widgets/centre_dashboard_sections.dart';
import '../widgets/centre_metric_card.dart';

String? activeCentre(WidgetRef ref) =>
    ref.watch(selectedCentreProvider) ??
    ref.watch(myCentresProvider).asData?.value.firstOrNull?.membershipId;

class CentreDashboardScreen extends ConsumerWidget {
  const CentreDashboardScreen({super.key, this.state});
  final AsyncValue<CentreDashboard>? state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supplied = state;
    if (supplied != null) return _DashboardState(state: supplied);
    final membershipId = activeCentre(ref);
    if (membershipId == null) {
      return const Center(child: Text('No active centre membership'));
    }
    return _DashboardState(
      state: ref.watch(centreDashboardProvider(membershipId)),
    );
  }
}

class _DashboardState extends StatelessWidget {
  const _DashboardState({required this.state});
  final AsyncValue<CentreDashboard> state;

  @override
  Widget build(BuildContext context) => state.when(
    loading: () => const Center(child: CircularProgressIndicator()),
    error: (_, _) => const Center(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Text('The centre dashboard is unavailable. Try again.'),
      ),
    ),
    data: (dashboard) => CentreDashboardView(dashboard: dashboard),
  );
}

class CentreDashboardView extends StatelessWidget {
  const CentreDashboardView({super.key, required this.dashboard});
  final CentreDashboard dashboard;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final tablet = constraints.maxWidth >= 760;
      final summary = _Summary(dashboard: dashboard, tablet: tablet);
      final operations = CentreDashboardSections(dashboard: dashboard);
      return SingleChildScrollView(
        key: Key(tablet ? 'centre-dashboard-tablet' : 'centre-dashboard-phone'),
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              dashboard.centre.name,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              'Today’s operating picture',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            if (tablet)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: summary),
                  const SizedBox(width: AppSpacing.xl),
                  Expanded(child: operations),
                ],
              )
            else ...[
              summary,
              const SizedBox(height: AppSpacing.lg),
              operations,
            ],
          ],
        ),
      );
    },
  );
}

class _Summary extends StatelessWidget {
  const _Summary({required this.dashboard, required this.tablet});
  final CentreDashboard dashboard;
  final bool tablet;

  @override
  Widget build(BuildContext context) {
    final value = dashboard.indicativeValue;
    final noShow = dashboard.noShow;
    final cards = [
      CentreMetricCard.money(
        label: 'Indicative booking value',
        currencyCode: value.currencyCode,
        valueMinor: value.currentMonthMinor,
        comparisonMinor: value.previousMonthMinor,
      ),
      CentreMetricCard.comparison(
        label: 'Sessions',
        value: dashboard.sessions.currentMonth,
        comparison: dashboard.sessions.previousMonth,
      ),
      CentreMetricCard(label: 'Members', value: '${dashboard.members.total}'),
      CentreMetricCard(
        label: 'Active in 30 days',
        value: '${dashboard.members.active30Days.length}',
      ),
      CentreMetricCard(
        label: 'No-shows',
        value: noShow.rate == null ? '—' : '${(noShow.rate! * 100).round()}%',
        detail: '${noShow.numerator} of ${noShow.denominator}',
      ),
      CentreMetricCard(
        label: "Today's bookings",
        value: '${dashboard.todayBookings.length}',
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GridView.count(
          crossAxisCount: tablet ? 2 : 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: tablet ? 1.35 : 0.82,
          mainAxisSpacing: AppSpacing.sm,
          crossAxisSpacing: AppSpacing.sm,
          children: cards,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Indicative values are planning estimates, not payment revenue.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        CentreUtilisationSection(items: dashboard.utilisation),
        const SizedBox(height: AppSpacing.lg),
        _FutureNotice(),
      ],
    );
  }
}

class _FutureNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(AppRadii.small),
    ),
    child: const Text(
      'Personalised service outcomes arrive in F12. The research view arrives in F13.',
    ),
  );
}
