import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../core/widgets/async_action.dart';
import '../../journal/providers/wellness_provider.dart';
import '../providers/ring_provider.dart';

class WearablesScreen extends ConsumerStatefulWidget {
  const WearablesScreen({super.key});
  @override
  ConsumerState<WearablesScreen> createState() => _WearablesScreenState();
}

class _WearablesScreenState extends ConsumerState<WearablesScreen> {
  int _day = 0;
  String _metric = 'heartRate';
  Timer? _liveClock;

  @override
  void initState() {
    super.initState();
    _liveClock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(ringProvider).connected) setState(() {});
    });
  }

  @override
  void dispose() {
    _liveClock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ringProvider);
    final saved = ref.watch(wellnessProvider).asData?.value.ring ?? {};
    final report = state.snapshot.isNotEmpty
        ? state.snapshot
        : Map<String, dynamic>.from(saved['report'] as Map? ?? {});
    final now = DateTime.now();
    final requestedDate = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: _day)).toIso8601String().substring(0, 10);
    final history = Map<String, dynamic>.from(
      (saved['reports'] as Map? ?? {})[requestedDate] as Map? ?? {},
    );
    final records = Map<String, dynamic>.from(history['records'] as Map? ?? {});
    final points = (records[_metric] as List? ?? [])
        .whereType<num>()
        .where((n) => n.isFinite && n > 0)
        .map((n) => n.toDouble())
        .toList();
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Wearables', style: theme.textTheme.headlineLarge),
            ),
            IconButton(
              tooltip: 'Add ring',
              onPressed: () => context.push('/add-ring'),
              icon: const Icon(Icons.add_circle_outline),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0D4A43), Color(0xFF082B31)],
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33082B31),
                blurRadius: 24,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 70,
                    height: 70,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [Color(0xFFBDF6DF), Color(0xFF5AC8A6)],
                      ),
                    ),
                    child: const Icon(
                      Icons.trip_origin_rounded,
                      size: 46,
                      color: Color(0xFF083A35),
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 9,
                          color: state.connected
                              ? const Color(0xFF77E6BB)
                              : const Color(0xFFFFD38A),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          state.connected ? 'Connected' : 'Ready',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                saved['name'] as String? ?? 'A closer connection to you.',
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                state.connected
                    ? 'Connected · receiving available data'
                    : saved.isEmpty
                    ? 'Add your Mini Zone ring to begin.'
                    : 'Saved ring · tap Sync to connect',
                style: const TextStyle(color: Color(0xFFD7EDE6)),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 12,
                children: [
                  _InfoPill(
                    icon: Icons.battery_5_bar_rounded,
                    text: '${report['battery'] ?? '—'}%',
                  ),
                  _InfoPill(
                    icon: Icons.memory_rounded,
                    text: 'v${report['firmware'] ?? '—'}',
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (saved.isEmpty) ...[
          FilledButton.icon(
            onPressed: () => context.push('/add-ring'),
            icon: const Icon(Icons.bluetooth_searching),
            label: const Text('Add ring'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => context.push('/activity-session'),
            icon: const Icon(Icons.play_circle_outline_rounded),
            label: const Text('Start ring activity'),
          ),
        ] else ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: state.busy
                    ? null
                    : () => ref.read(ringProvider.notifier).sync(day: _day),
                icon: const Icon(Icons.sync),
                label: Text(state.busy ? 'Syncing…' : 'Sync ring'),
              ),
              OutlinedButton(
                onPressed: () => ref.read(ringProvider.notifier).disconnect(),
                child: const Text('Disconnect'),
              ),
              TextButton(
                onPressed: () async {
                  final yes = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Forget this ring?'),
                      content: const Text(
                        'Saved measurements remain. This will not factory-reset the ring.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('Forget'),
                        ),
                      ],
                    ),
                  );
                  if (yes == true && context.mounted) {
                    await runAction(
                      context,
                      () => ref.read(ringProvider.notifier).forget(),
                    );
                  }
                },
                child: const Text('Forget'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _day,
            decoration: const InputDecoration(labelText: 'History day to sync'),
            items: List.generate(
              7,
              (i) => DropdownMenuItem(
                value: i,
                child: Text(
                  i == 0 ? 'Today' : '$i day${i == 1 ? '' : 's'} ago',
                ),
              ),
            ),
            onChanged: state.busy
                ? null
                : (v) {
                    if (v != null) setState(() => _day = v);
                  },
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => context.push('/activity-session'),
            icon: const Icon(Icons.play_circle_outline_rounded),
            label: const Text('Start ring activity'),
          ),
        ],
        const SizedBox(height: 16),
        if (state.busy) const LinearProgressIndicator(),
        Text(state.message),
        if (state.connected && report['observedAt'] is num)
          Text(
            _readingAge((report['observedAt'] as num).toInt()),
            style: theme.textTheme.bodySmall,
          ),
        if (state.error != null)
          Text(state.error!, style: TextStyle(color: theme.colorScheme.error)),
        if (saved['lastSync'] != null)
          Text(
            'Last saved sync: ${DateFormat.MMMd().add_jm().format(DateTime.parse(saved['lastSync'] as String))}',
          ),
        const SizedBox(height: 24),
        Text('Latest available readings', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.12,
          children: [
            _MetricCard(
              icon: Icons.favorite_rounded,
              label: 'Heart rate',
              value: report['heartRate'],
              unit: 'BPM',
              color: const Color(0xFFE95970),
            ),
            _MetricCard(
              icon: Icons.directions_walk_rounded,
              label: 'Steps',
              value: report['steps'],
              unit: 'today',
              color: const Color(0xFF4B8FE8),
            ),
            _MetricCard(
              icon: Icons.water_drop_rounded,
              label: 'Blood oxygen',
              value: report['spo2'],
              unit: '%',
              color: const Color(0xFF36A9AE),
            ),
            _MetricCard(
              icon: Icons.bolt_rounded,
              label: 'Stress',
              value: report['stress'],
              unit: 'index',
              color: const Color(0xFFF3A646),
            ),
            _MetricCard(
              icon: Icons.monitor_heart_rounded,
              label: 'HRV',
              value: report['hrv'],
              unit: 'ms',
              color: const Color(0xFF8B73D6),
            ),
            _MetricCard(
              icon: Icons.bedtime_rounded,
              label: 'Sleep',
              value: report['sleepMinutes'] == null
                  ? null
                  : _sleepLabel(report['sleepMinutes']),
              unit: 'duration',
              color: const Color(0xFF5366B5),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Ring history', style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _metric,
                  items:
                      const {
                            'heartRate': 'Heart rate',
                            'steps': 'Steps',
                            'spo2': 'Blood oxygen',
                            'stress': 'Stress',
                            'hrv': 'HRV',
                          }.entries
                          .map(
                            (m) => DropdownMenuItem(
                              value: m.key,
                              child: Text(m.value),
                            ),
                          )
                          .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _metric = v);
                  },
                ),
                const SizedBox(height: 24),
                if (points.length < 2)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Not enough ring history yet. Wear your ring and sync again.',
                    ),
                  )
                else
                  SizedBox(
                    height: 170,
                    child: LineChart(
                      LineChartData(
                        borderData: FlBorderData(show: false),
                        titlesData: const FlTitlesData(show: false),
                        gridData: const FlGridData(drawVerticalLine: false),
                        lineBarsData: [
                          LineChartBarData(
                            spots: [
                              for (var i = 0; i < points.length; i++)
                                FlSpot(i.toDouble(), points[i]),
                            ],
                            dotData: const FlDotData(show: false),
                            color: theme.colorScheme.primary,
                            barWidth: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  '${points.length} available samples · requested date $requestedDate. Sample order is shown because the SDK does not supply verified per-sample timestamps.',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Ring readings and daily history are saved to your health timeline and synced to your account.',
        ),
      ],
    );
  }

  static String _sleepLabel(dynamic value) {
    final minutes = value is num ? value.toInt() : 0;
    return '${minutes ~/ 60}h ${minutes % 60}m';
  }

  static String _readingAge(int milliseconds) {
    final seconds = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(milliseconds))
        .inSeconds;
    if (seconds <= 1) return 'Live reading · updated now';
    return 'Live reading · updated ${seconds}s ago';
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17, color: const Color(0xFFBDF6DF)),
        const SizedBox(width: 7),
        Text(text, style: const TextStyle(color: Colors.white)),
      ],
    ),
  );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });
  final IconData icon;
  final String label;
  final dynamic value;
  final String unit;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: .55),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: .13),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 20, color: color),
            ),
            const Spacer(),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  child: Text(
                    '${value ?? '—'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(unit, style: theme.textTheme.bodySmall),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
