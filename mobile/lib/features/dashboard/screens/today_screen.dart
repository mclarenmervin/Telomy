import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/widgets/quick_log.dart';
import '../../auth/providers/auth_provider.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../journal/data/wellness_analytics.dart';
import '../../journal/models/journal_entry.dart';
import '../widgets/trend_chart.dart';
import '../../../core/config/feature_flags.dart';
import '../../health/services/longi_score_service.dart';
import '../../biological_age/data/biological_age_service.dart';

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(wellnessProvider);
    final scoreMeasurements = ref
        .watch(displayedMeasurementsProvider)
        .asData
        ?.value;
    final d = state.asData?.value;
    final now = DateTime.now();
    final name =
        d?.profile['fullName'] ??
        ref.watch(authProvider).asData?.value?.fullName ??
        'there';
    final a = d == null
        ? null
        : WellnessAnalytics(d, DateTime(now.year, now.month, now.day), now);
    final days = <String>{
      for (final e in d?.entries ?? [])
        if (!e.recordedAt.isAfter(now) &&
            e.recordedAt.isAfter(now.subtract(const Duration(days: 7))))
          DateFormat('yyyy-MM-dd').format(e.recordedAt),
      for (final m in d?.measurements ?? [])
        if (!m.recordedAt.isAfter(now) &&
            m.recordedAt.isAfter(now.subtract(const Duration(days: 7))))
          DateFormat('yyyy-MM-dd').format(m.recordedAt),
    }.length;
    final theme = Theme.of(context);
    final longiScore = d == null || scoreMeasurements == null
        ? null
        : const LongiScoreService().calculate(
            data: d,
            measurements: scoreMeasurements,
            date: now,
          );
    final biologicalAge = d == null || scoreMeasurements == null
        ? null
        : const BiologicalAgeService().calculate(
            data: d,
            measurements: scoreMeasurements,
            date: now,
          );
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    DateFormat('EEEE, d MMMM').format(now),
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Hi ${name.trim().split(' ').first}',
                    style: theme.textTheme.headlineLarge,
                  ),
                ],
              ),
            ),
            IconButton.filledTonal(
              onPressed: () => context.go('/profile'),
              icon: const Icon(Icons.person_outline),
            ),
          ],
        ),
        const SizedBox(height: 22),
        if (state.isLoading) const LinearProgressIndicator(),
        if (state.hasError)
          TextButton(
            onPressed: () => ref.invalidate(wellnessProvider),
            child: const Text('Unable to load records. Retry'),
          ),
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const LinearGradient(
              colors: [Color(0xFF1F5C4E), Color(0xFF18483E)],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  SincOrb(size: 28),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Sinc · your daily picture',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                d == null
                    ? 'Your daily picture will appear here.'
                    : d.entries.isEmpty && d.measurements.isEmpty
                    ? 'Start with one small detail. A meal, a walk, or how you feel today.'
                    : 'Today you logged ${a!.total(EntryKind.workout, 'duration').round()} active minutes and ${a.total(EntryKind.water, 'amount').round()} ml of water.',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF1F5C4E),
                    ),
                    onPressed: () => context.go('/sinc'),
                    child: const Text('Explore my data'),
                  ),
                  TextButton(
                    onPressed: () => showQuickLog(context),
                    child: const Text(
                      'Log today',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'LONGISCORE',
                        style: TextStyle(fontSize: 10, letterSpacing: 1.4),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        FeatureFlags.longiScore
                            ? longiScore?.value?.toString() ?? 'Learning'
                            : 'Not available',
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        FeatureFlags.longiScore
                            ? 'Coverage ${((longiScore?.coverage ?? 0) * 100).round()}%'
                            : 'Requires a validated scoring model.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'BIOLOGICAL AGE',
                        style: TextStyle(fontSize: 10, letterSpacing: 1.4),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        FeatureFlags.biologicalAge
                            ? biologicalAge?.estimatedAge?.toStringAsFixed(1) ??
                                  'Learning'
                            : 'Not available',
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        FeatureFlags.biologicalAge
                            ? 'Confidence ${((biologicalAge?.confidence ?? 0) * 100).round()}%'
                            : 'Estimate remains disabled.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                SizedBox(
                  width: 76,
                  height: 76,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: days / 7,
                          strokeWidth: 5,
                          backgroundColor: theme.colorScheme.primaryContainer,
                        ),
                      ),
                      Text('$days / 7', style: theme.textTheme.titleLarge),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'YOUR DATA',
                        style: TextStyle(fontSize: 10, letterSpacing: 1.5),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'Building your picture',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'Days with records in the past week. Every detail adds context.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 26),
        Text('Do one thing', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.all(14),
            leading: const SincOrb(),
            title: const Text('Capture a little of today'),
            subtitle: const Text('Meals, movement, mood & more'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showQuickLog(context),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.bluetooth),
            title: const Text('Your ring, connected'),
            subtitle: const Text('Connect or sync your Mini Zone ring'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/devices'),
          ),
        ),
        const SizedBox(height: 26),
        Text('Today, at a glance', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            ActionChip(
              avatar: const Icon(Icons.monitor_heart_outlined),
              label: const Text('Heart & vitals'),
              onPressed: () => context.push('/vitals'),
            ),
            ActionChip(
              avatar: const Icon(Icons.bedtime_outlined),
              label: const Text('Sleep'),
              onPressed: () => context.push('/sleep'),
            ),
            ActionChip(
              avatar: const Icon(Icons.battery_charging_full_outlined),
              label: const Text('Readiness'),
              onPressed: () => context.push('/readiness'),
            ),
            ActionChip(
              avatar: const Icon(Icons.air_outlined),
              label: const Text('Stress'),
              onPressed: () => context.push('/stress'),
            ),
            ActionChip(
              avatar: const Icon(Icons.directions_walk),
              label: const Text('Activity'),
              onPressed: () => context.push('/activity'),
            ),
            ActionChip(
              avatar: const Icon(Icons.monitor_weight_outlined),
              label: const Text('Body'),
              onPressed: () => context.push('/body'),
            ),
            ActionChip(
              label: Text('${a?.totalSteps.round() ?? 0} steps'),
              onPressed: () => context.push('/health'),
            ),
            ActionChip(
              label: Text(
                '${a?.total(EntryKind.meal, 'calories').round() ?? 0} kcal logged',
              ),
              onPressed: () => context.push('/nutrition'),
            ),
            ActionChip(
              label: const Text('Your timeline'),
              onPressed: () => context.push('/timeline'),
            ),
          ],
        ),
      ],
    );
  }
}

class TrendsScreen extends ConsumerWidget {
  const TrendsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final measurements =
        ref.watch(displayedMeasurementsProvider).asData?.value ?? [];
    final state = ref.watch(wellnessProvider);
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Text('Trends', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text('Your patterns, over time.'),
        const SizedBox(height: 24),
        if (state.asData?.value.demo == true)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text('SAMPLE PREVIEW · Manage in Settings'),
          ),
        if (state.isLoading)
          const LinearProgressIndicator()
        else if (state.hasError)
          TextButton(
            onPressed: () => ref.invalidate(wellnessProvider),
            child: const Text('Unable to load trends. Retry'),
          )
        else if (measurements.isNotEmpty)
          TrendChart(measurements: measurements)
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const SincOrb(size: 60),
                  const SizedBox(height: 16),
                  const Text('Your first reading starts the story.'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => showQuickLog(context),
                    child: const Text('Add a reading'),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 20),
        for (final item in const {
          'reports': 'Summaries & date ranges',
          'health': 'All health readings',
          'timeline': 'Life events & daily logs',
          'plans': 'Your personal plans',
        }.entries)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              title: Text(item.value),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/${item.key}'),
            ),
          ),
      ],
    );
  }
}
