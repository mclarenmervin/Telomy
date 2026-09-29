import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../health/models/health_measurement.dart';
import '../providers/dashboard_provider.dart';
import 'metric_card.dart';

class TrendChart extends ConsumerWidget {
  const TrendChart({super.key, required this.measurements});
  final List<HealthMeasurement> measurements;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requested = ref.watch(trendProvider);
    final selection =
        measurements.any((m) => m.measurementType == requested.type)
        ? requested
        : TrendSelection(
            type: measurements.first.measurementType,
            period: requested.period,
          );
    final values = filterTrend(measurements, selection, DateTime.now());
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your rhythm', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'A little perspective on your everyday.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<MeasurementType>(
              initialValue: selection.type,
              key: ValueKey(selection.type),
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Metric'),
              items: MeasurementType.values
                  .where((t) => measurements.any((m) => m.measurementType == t))
                  .map(
                    (t) =>
                        DropdownMenuItem(value: t, child: Text(metricLabel(t))),
                  )
                  .toList(),
              onChanged: (type) {
                if (type != null) {
                  ref.read(trendProvider.notifier).selectType(type);
                }
              },
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: TrendPeriod.values
                  .map(
                    (p) => ChoiceChip(
                      label: Text(
                        '${p.name[0].toUpperCase()}${p.name.substring(1)}',
                      ),
                      selected: p == selection.period,
                      onSelected: (_) =>
                          ref.read(trendProvider.notifier).selectPeriod(p),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 24),
            if (values.isEmpty)
              const SizedBox(
                height: 160,
                child: Center(child: Text('No readings in this period.')),
              )
            else if (values.length == 1)
              SizedBox(
                height: 160,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${metricValue(values.single)} ${values.single.unit}',
                        style: theme.textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'One reading in this period. More readings build a trend.',
                      ),
                    ],
                  ),
                ),
              )
            else
              Semantics(
                label:
                    '${metricLabel(selection.type)} chart with ${values.length} readings, from ${metricValue(values.first)} to ${metricValue(values.last)} ${values.last.unit}',
                child: SizedBox(
                  height: 170,
                  child: LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: values.last.recordedAt
                          .difference(values.first.recordedAt)
                          .inMilliseconds
                          .toDouble()
                          .clamp(1, double.infinity),
                      gridData: const FlGridData(
                        show: true,
                        drawVerticalLine: false,
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: const FlTitlesData(show: false),
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipItems: (spots) => spots.map((spot) {
                            final m = values[spot.spotIndex];
                            return LineTooltipItem(
                              '${DateFormat.MMMd().add_jm().format(m.recordedAt)}\n${metricValue(m)} ${m.unit}',
                              TextStyle(
                                color: theme.colorScheme.onInverseSurface,
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: [
                            for (var i = 0; i < values.length; i++)
                              FlSpot(
                                values[i].recordedAt
                                    .difference(values.first.recordedAt)
                                    .inMilliseconds
                                    .toDouble(),
                                values[i].value,
                              ),
                          ],
                          isCurved: false,
                          color: theme.colorScheme.primary,
                          barWidth: 3,
                          dotData: const FlDotData(show: true),
                          belowBarData: BarAreaData(
                            show: true,
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.09,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (values.isNotEmpty)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(DateFormat.MMMd().format(values.first.recordedAt)),
                  Text(DateFormat.MMMd().format(values.last.recordedAt)),
                ],
              ),
            const SizedBox(height: 14),
            const Text(
              'Only available readings are shown. Missing periods are not filled with estimated values.',
            ),
          ],
        ),
      ),
    );
  }
}
