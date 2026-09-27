import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../journal/data/wellness_analytics.dart';
import '../../health/models/health_measurement.dart';
import '../../dashboard/widgets/metric_card.dart';
import '../data/weekly_report.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});
  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  DateTimeRange? _custom;
  int _days = 7;
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final from =
        _custom?.start ??
        DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(Duration(days: _days - 1));
    final to = _custom == null
        ? now
        : DateTime(
            _custom!.end.year,
            _custom!.end.month,
            _custom!.end.day,
            23,
            59,
            59,
          );
    final data = ref.watch(wellnessProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Your health report',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            for (final p in const {
              1: 'Daily',
              7: 'Weekly',
              30: 'Monthly',
            }.entries)
              ChoiceChip(
                label: Text(p.value),
                selected: _custom == null && _days == p.key,
                onSelected: (_) => setState(() {
                  _custom = null;
                  _days = p.key;
                }),
              ),
            ActionChip(
              label: const Text('Custom dates'),
              onPressed: () async {
                final dates = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(1900),
                  lastDate: now,
                );
                if (dates != null && mounted) setState(() => _custom = dates);
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '${DateFormat.yMMMd().format(from)} – ${DateFormat.yMMMd().format(to)}',
        ),
        const SizedBox(height: 24),
        ...data.when(
          loading: () => [const LinearProgressIndicator()],
          error: (_, s) => [
            TextButton(
              onPressed: () => ref.invalidate(wellnessProvider),
              child: const Text('Retry loading records'),
            ),
          ],
          data: (d) {
            final a = WellnessAnalytics(d, from, to);
            final weekly = _custom == null && _days == 7
                ? const WeeklyReportService().build(d, now)
                : null;
            return [
              if (weekly != null) ...[
                _WeeklyHero(weekly),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _ProgressCard(
                        label: 'Active days',
                        value: weekly.activeDays,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ProgressCard(
                        label: 'Days with data',
                        value: weekly.loggedDays,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Week over week',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        for (final metric in weekly.metrics)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(metric.label),
                            subtitle: Text(
                              metric.change == null
                                  ? 'Previous-week comparison unavailable'
                                  : '${metric.change! >= 0 ? '+' : ''}${metric.change!.toStringAsFixed(0)}% vs previous week',
                            ),
                            trailing: Text(
                              metric.value == null
                                  ? '—'
                                  : '${metric.value!.toStringAsFixed(metric.value! >= 100 ? 0 : 1)} ${metric.unit}',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Highlights',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 10),
                        for (final highlight in weekly.highlights)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text('• $highlight'),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: _weeklyText(weekly)),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Weekly report copied')),
                      );
                    }
                  },
                  icon: const Icon(Icons.ios_share_outlined),
                  label: const Text('Copy weekly report'),
                ),
                const SizedBox(height: 24),
              ],
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: SelectableText(
                    a.summary(),
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Vitals & trends',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              for (final type in MeasurementType.values)
                if (a.readings(type).isNotEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(metricLabel(type)),
                    subtitle: Text(
                      '${a.readings(type).length} readings · ${a.readings(type).map((m) => m.source.name).toSet().join(', ')}',
                    ),
                    trailing: Text(
                      '${a.average(type)!.toStringAsFixed(1)} ${a.readings(type).last.unit}',
                    ),
                  ),
              const SizedBox(height: 16),
              Text(
                'Events & context',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              for (final e in a.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(e.title),
                  subtitle: Text(
                    '${e.kind.name} · ${DateFormat.MMMd().format(e.recordedAt)}\n${e.notes}',
                  ),
                ),
              const SizedBox(height: 20),
              const Text(
                'This report uses your saved personal records. Demo preview readings are excluded.',
              ),
            ];
          },
        ),
      ],
    );
  }

  String _weeklyText(WeeklyReport report) {
    final buffer = StringBuffer(
      'Telomy weekly report\n'
      '${DateFormat.yMMMd().format(report.from)} – ${DateFormat.yMMMd().format(report.to)}\n\n'
      'LongiScore: ${report.score?.toStringAsFixed(0) ?? 'Unavailable'}\n'
      'Active days: ${report.activeDays}/7\n'
      'Days with data: ${report.loggedDays}/7\n\n',
    );
    for (final metric in report.metrics) {
      buffer.writeln(
        '${metric.label}: ${metric.value?.toStringAsFixed(1) ?? 'Unavailable'} ${metric.unit}',
      );
    }
    buffer.writeln('\nHighlights');
    for (final highlight in report.highlights) {
      buffer.writeln('• $highlight');
    }
    buffer.writeln('\nWellness summary only; not medical advice.');
    return buffer.toString();
  }
}

class _WeeklyHero extends StatelessWidget {
  const _WeeklyHero(this.report);
  final WeeklyReport report;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          CircleAvatar(
            radius: 34,
            child: Text(
              report.score?.toStringAsFixed(0) ?? '—',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Weekly LongiScore',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  report.scoreChange == null
                      ? 'Comparison available after another week'
                      : '${report.scoreChange! >= 0 ? '+' : ''}${report.scoreChange!.toStringAsFixed(0)}% from the previous week',
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.label, required this.value});
  final String label;
  final int value;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$value / 7', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: value / 7),
          const SizedBox(height: 8),
          Text(label),
        ],
      ),
    ),
  );
}
