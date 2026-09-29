import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../dashboard/widgets/metric_card.dart';
import '../../journal/providers/wellness_provider.dart';
import '../models/health_measurement.dart';

enum VitalRange {
  day('Day', 1),
  week('Week', 7),
  month('Month', 30);

  const VitalRange(this.label, this.days);
  final String label;
  final int days;
}

class VitalsScreen extends ConsumerStatefulWidget {
  const VitalsScreen({super.key});

  @override
  ConsumerState<VitalsScreen> createState() => _VitalsScreenState();
}

class _VitalsScreenState extends ConsumerState<VitalsScreen> {
  static const vitalTypes = <MeasurementType>[
    MeasurementType.heartRate,
    MeasurementType.restingHeartRate,
    MeasurementType.hrv,
    MeasurementType.spo2,
    MeasurementType.temperature,
    MeasurementType.respiratoryRate,
    MeasurementType.bloodPressure,
  ];
  MeasurementType selected = MeasurementType.heartRate;
  VitalRange range = VitalRange.week;

  @override
  Widget build(BuildContext context) {
    final readings = ref.watch(displayedMeasurementsProvider);
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Heart & vitals',
                style: theme.textTheme.headlineLarge,
              ),
            ),
            IconButton(
              tooltip: 'Health sources',
              onPressed: () => context.push('/health-consent'),
              icon: const Icon(Icons.add_link),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Measured and imported observations, with their original source and time.',
        ),
        const SizedBox(height: 22),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final type in vitalTypes)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(metricLabel(type)),
                    selected: selected == type,
                    onSelected: (_) => setState(() => selected = type),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SegmentedButton<VitalRange>(
          segments: [
            for (final value in VitalRange.values)
              ButtonSegment(value: value, label: Text(value.label)),
          ],
          selected: {range},
          onSelectionChanged: (value) => setState(() => range = value.single),
        ),
        const SizedBox(height: 22),
        readings.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Text('Vital records could not be loaded.'),
                  TextButton(
                    onPressed: () =>
                        ref.invalidate(displayedMeasurementsProvider),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
          data: (all) {
            final from = DateTime.now().subtract(Duration(days: range.days));
            final values =
                all
                    .where(
                      (m) =>
                          m.measurementType == selected &&
                          !m.recordedAt.isBefore(from),
                    )
                    .toList()
                  ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
            if (values.isEmpty) return _EmptyVital(type: selected);
            final numeric = values.map((m) => m.value).toList();
            final average = numeric.reduce((a, b) => a + b) / numeric.length;
            final minimum = numeric.reduce((a, b) => a < b ? a : b);
            final maximum = numeric.reduce((a, b) => a > b ? a : b);
            return Column(
              children: [
                _LatestVital(measurement: values.last),
                const SizedBox(height: 12),
                _VitalChart(values: values),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _SummaryCard(
                        label: 'Average',
                        value: average,
                        unit: values.last.unit,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _SummaryCard(
                        label: 'Range',
                        value: minimum,
                        second: maximum,
                        unit: values.last.unit,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Observations',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                const SizedBox(height: 8),
                for (final value in values.reversed.take(30))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${metricValue(value)} ${value.unit}'),
                    subtitle: Text(
                      '${DateFormat.MMMd().add_jm().format(value.recordedAt)} · ${value.source.name} · ${value.quality.name}',
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _EmptyVital extends StatelessWidget {
  const _EmptyVital({required this.type});
  final MeasurementType type;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(26),
      child: Column(
        children: [
          Icon(
            metricIcon(type),
            size: 42,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text('No ${metricLabel(type).toLowerCase()} data in this period.'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => context.push('/health-consent'),
            child: const Text('Connect a health source'),
          ),
        ],
      ),
    ),
  );
}

class _LatestVital extends StatelessWidget {
  const _LatestVital({required this.measurement});
  final HealthMeasurement measurement;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          Icon(
            metricIcon(measurement.measurementType),
            size: 38,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Latest ${metricLabel(measurement.measurementType).toLowerCase()}',
                ),
                const SizedBox(height: 6),
                Text(
                  '${metricValue(measurement)} ${measurement.unit}',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 5),
                Text(
                  '${DateFormat.MMMd().add_jm().format(measurement.recordedAt)} · ${measurement.source.name}',
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.label,
    required this.value,
    required this.unit,
    this.second,
  });
  final String label;
  final double value;
  final double? second;
  final String unit;

  String number(double input) => input == input.roundToDouble()
      ? input.round().toString()
      : input.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 8),
          FittedBox(
            child: Text(
              second == null
                  ? '${number(value)} $unit'
                  : '${number(value)}–${number(second!)} $unit',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ],
      ),
    ),
  );
}

class _VitalChart extends StatelessWidget {
  const _VitalChart({required this.values});
  final List<HealthMeasurement> values;

  @override
  Widget build(BuildContext context) {
    if (values.length == 1) {
      return const Card(
        child: SizedBox(
          height: 180,
          child: Center(
            child: Text('One observation · more data will build a trend.'),
          ),
        ),
      );
    }
    final start = values.first.recordedAt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 14),
        child: SizedBox(
          height: 190,
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: values.last.recordedAt
                  .difference(start)
                  .inMilliseconds
                  .toDouble()
                  .clamp(1, double.infinity),
              borderData: FlBorderData(show: false),
              gridData: const FlGridData(drawVerticalLine: false),
              titlesData: const FlTitlesData(show: false),
              lineBarsData: [
                LineChartBarData(
                  spots: [
                    for (final value in values)
                      FlSpot(
                        value.recordedAt
                            .difference(start)
                            .inMilliseconds
                            .toDouble(),
                        value.value,
                      ),
                  ],
                  isCurved: false,
                  barWidth: 3,
                  color: Theme.of(context).colorScheme.primary,
                  dotData: FlDotData(show: values.length < 20),
                  belowBarData: BarAreaData(
                    show: true,
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: .08),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
