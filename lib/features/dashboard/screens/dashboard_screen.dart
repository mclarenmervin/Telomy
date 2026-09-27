import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../auth/providers/auth_provider.dart';
import '../../health/models/health_measurement.dart';
import '../../health/screens/measurement_editor.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../journal/models/journal_entry.dart';
import '../../journal/screens/entry_editor.dart';
import '../../journal/data/wellness_analytics.dart';
import '../../../core/widgets/async_action.dart';
import '../providers/dashboard_provider.dart';
import '../widgets/metric_card.dart';
import '../widgets/trend_chart.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key, this.healthOnly = false});
  final bool healthOnly;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(wellnessProvider);
    final readings = ref.watch(displayedMeasurementsProvider);
    final user = ref.watch(authProvider).asData?.value;
    final theme = Theme.of(context);
    final now = DateTime.now();
    final name = data.asData?.value.profile['fullName'];
    final displayName = name?.isNotEmpty == true
        ? name!
        : user?.fullName ?? 'there';
    final greeting = now.hour < 12
        ? 'Good morning'
        : now.hour < 17
        ? 'Good afternoon'
        : 'Good evening';
    final demo = data.asData?.value.demo ?? false;
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(wellnessProvider);
        await ref.read(wellnessProvider.future);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 32),
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(
                  'assets/branding/telomy-icon.png',
                  width: 36,
                  height: 36,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'TELOMY',
                  style: TextStyle(
                    letterSpacing: 3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Wearables',
                onPressed: () => context.push('/devices'),
                icon: const Icon(Icons.watch_outlined),
              ),
            ],
          ),
          const SizedBox(height: 26),
          Text(
            DateFormat('EEEE, MMMM d').format(now).toUpperCase(),
            style: theme.textTheme.labelMedium,
          ),
          const SizedBox(height: 8),
          Text(
            healthOnly
                ? 'Your health, in focus.'
                : '$greeting,\n${displayName.split(' ').first}.',
            style: theme.textTheme.headlineLarge,
          ),
          const SizedBox(height: 12),
          const Text('Your daily details. One connected picture.'),
          const SizedBox(height: 24),
          if (demo)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'SAMPLE PREVIEW · Switch off in Settings to see personal readings.',
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: data.asData == null
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const MeasurementEditor(),
                        ),
                      ),
                icon: const Icon(Icons.add),
                label: const Text('Log reading'),
              ),
              OutlinedButton.icon(
                onPressed: () => context.push('/add-ring'),
                icon: const Icon(Icons.bluetooth),
                label: const Text('Add ring'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (!healthOnly && data.asData != null)
            Builder(
              builder: (context) {
                final d = data.asData!.value;
                final a = WellnessAnalytics(
                  d,
                  DateTime(now.year, now.month, now.day),
                  now,
                );
                final water = a.total(EntryKind.water, 'amount');
                return Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF123F3A),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'TODAY, AT A GLANCE',
                        style: TextStyle(
                          color: Color(0xFFBDE2D3),
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '${a.totalSteps.round()} steps\n${a.total(EntryKind.workout, 'duration').round()} active minutes',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '${a.total(EntryKind.meal, 'calories').round()} kcal logged · ${water.round()} ml water',
                        style: const TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: (water / d.goal('waterGoal', 2000)).clamp(0, 1),
                        minHeight: 7,
                        borderRadius: BorderRadius.circular(5),
                        color: const Color(0xFF9DE3CA),
                        backgroundColor: Colors.white12,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Water goal: ${d.goal('waterGoal', 2000).round()} ml · edit in Profile',
                        style: const TextStyle(color: Color(0xFFBDE2D3)),
                      ),
                    ],
                  ),
                );
              },
            ),
          const SizedBox(height: 24),
          if (!healthOnly) ...[
            Text('Make today count', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  label: const Text('Log meal'),
                  avatar: const Icon(Icons.restaurant_outlined),
                  onPressed: data.asData == null
                      ? null
                      : () => openEntryEditor(context, EntryKind.meal),
                ),
                ActionChip(
                  label: const Text('Log workout'),
                  avatar: const Icon(Icons.fitness_center),
                  onPressed: data.asData == null
                      ? null
                      : () => openEntryEditor(context, EntryKind.workout),
                ),
                ActionChip(
                  label: const Text('Log water'),
                  avatar: const Icon(Icons.water_drop_outlined),
                  onPressed: data.asData == null
                      ? null
                      : () => openEntryEditor(context, EntryKind.water),
                ),
                ActionChip(
                  label: const Text('Plans & progress'),
                  onPressed: () => context.push('/fitness'),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
          Text('Latest measurements', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
            'Each card shows the latest saved observation, which may be from a previous day.',
          ),
          const SizedBox(height: 16),
          ...readings.when(
            loading: () => [const LinearProgressIndicator()],
            error: (_, s) => [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const Text('Your records could not be loaded.'),
                      TextButton(
                        onPressed: () => ref.invalidate(wellnessProvider),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            data: (values) {
              if (values.isEmpty) {
                return [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.monitor_heart_outlined, size: 40),
                          const SizedBox(height: 16),
                          Text(
                            'Start with one reading.',
                            style: theme.textTheme.titleLarge,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'Log a measurement or connect your ring. Your charts grow with your actual records.',
                          ),
                        ],
                      ),
                    ),
                  ),
                ];
              }
              return [
                LayoutBuilder(
                  builder: (context, c) {
                    final scale = MediaQuery.textScalerOf(context).scale(1);
                    final columns = c.maxWidth >= 900
                        ? 4
                        : c.maxWidth >= 580
                        ? 3
                        : c.maxWidth < 300 || scale > 1.4
                        ? 1
                        : 2;
                    final types = MeasurementType.values
                        .where((t) => values.any((m) => m.measurementType == t))
                        .toList();
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: types.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: 254 * scale.clamp(1, 3),
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemBuilder: (context, i) {
                        final series =
                            values
                                .where((m) => m.measurementType == types[i])
                                .toList()
                              ..sort(
                                (a, b) => a.recordedAt.compareTo(b.recordedAt),
                              );
                        return MetricCard(
                          measurement: series.last,
                          previous: series.length > 1
                              ? series[series.length - 2]
                              : null,
                          onTap: () {
                            ref
                                .read(trendProvider.notifier)
                                .selectType(types[i]);
                            showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              useSafeArea: true,
                              builder: (_) => DraggableScrollableSheet(
                                expand: false,
                                initialChildSize: .8,
                                builder: (_, scroll) => SingleChildScrollView(
                                  controller: scroll,
                                  padding: const EdgeInsets.all(16),
                                  child: TrendChart(measurements: values),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 24),
                TrendChart(measurements: values),
                if (healthOnly && !demo) ...[
                  const SizedBox(height: 24),
                  Text('Reading history', style: theme.textTheme.titleLarge),
                  for (final m in values.reversed.take(100))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${metricLabel(m.measurementType)} · ${metricValue(m)} ${m.unit}',
                      ),
                      subtitle: Text(
                        '${DateFormat.MMMd().add_jm().format(m.recordedAt)} · ${m.source.name}',
                      ),
                      trailing: IconButton(
                        tooltip: 'Delete reading',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final yes = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                              title: const Text('Delete reading?'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(c, false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(c, true),
                                  child: const Text('Delete'),
                                ),
                              ],
                            ),
                          );
                          if (yes == true && context.mounted) {
                            await runAction(
                              context,
                              () => ref
                                  .read(wellnessProvider.notifier)
                                  .deleteMeasurement(m.id),
                            );
                          }
                        },
                      ),
                    ),
                  if (values.length > 100)
                    Text(
                      'Showing the latest 100 of ${values.length} saved readings. Charts and reports use the full history.',
                    ),
                ],
              ];
            },
          ),
          const SizedBox(height: 24),
          if (!healthOnly)
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.trip_origin),
                    title: const Text('Your ring, connected'),
                    subtitle: const Text(
                      'Battery, live readings & health history',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/devices'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.insights_outlined),
                    title: const Text('Wellness insights'),
                    subtitle: const Text(
                      'Summaries calculated from your records',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/ai-copilot'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
