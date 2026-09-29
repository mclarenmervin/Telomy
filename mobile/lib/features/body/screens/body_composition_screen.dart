import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../dashboard/widgets/metric_card.dart';
import '../../health/models/health_measurement.dart';
import '../../health/screens/measurement_editor.dart';
import '../../journal/providers/wellness_provider.dart';
import '../data/body_composition_analysis.dart';

class BodyCompositionScreen extends ConsumerWidget {
  const BodyCompositionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final readings = ref.watch(displayedMeasurementsProvider);
    final wellness = ref.watch(wellnessProvider);
    final profile = wellness.asData?.value.profile ?? const <String, String>{};
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Text('Body composition', style: theme.textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text(
          'Measurements, calculated ratios and progress from your own records.',
        ),
        const SizedBox(height: 22),
        readings.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Body measurements could not be loaded.'),
            ),
          ),
          data: (values) {
            final summary = const BodyCompositionAnalysis().summarize(
              values,
              profile,
            );
            final target = double.tryParse(profile['targetWeight'] ?? '');
            final bodyValues =
                values
                    .where(
                      (value) => _bodyTypes.contains(value.measurementType),
                    )
                    .toList()
                  ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
            return Column(
              children: [
                _WeightProgress(weight: summary.weight, target: target),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.45,
                  children: [
                    _BodyMetric(
                      'BMI',
                      summary.bmi?.toStringAsFixed(1),
                      'Calculated from latest weight and profile height when no measured BMI exists.',
                    ),
                    _BodyMetric(
                      'Body fat',
                      _measurement(summary.bodyFat),
                      _source(summary.bodyFat),
                    ),
                    _BodyMetric(
                      'Muscle mass',
                      _measurement(summary.muscleMass),
                      _source(summary.muscleMass),
                    ),
                    _BodyMetric(
                      'Waist',
                      _measurement(summary.waist) ??
                          _profileValue(profile['waist'], 'cm'),
                      _source(summary.waist),
                    ),
                    _BodyMetric(
                      'Waist / height',
                      summary.waistToHeight?.toStringAsFixed(2),
                      'Calculated ratio',
                    ),
                    _BodyMetric(
                      'Waist / hip',
                      summary.waistToHip?.toStringAsFixed(2),
                      'Calculated ratio',
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Add measurement',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final type in _bodyTypes)
                      ActionChip(
                        label: Text(metricLabel(type)),
                        onPressed: () => _openEditor(context, type),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('History', style: theme.textTheme.titleLarge),
                ),
                const SizedBox(height: 8),
                if (bodyValues.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No body measurements yet.'),
                    ),
                  )
                else
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Column(
                        children: [
                          for (final value in bodyValues.take(50))
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                '${metricLabel(value.measurementType)} · ${metricValue(value)} ${value.unit}',
                              ),
                              subtitle: Text(
                                '${DateFormat.yMMMd().format(value.recordedAt)} · ${value.source.name} · ${value.quality.name}',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  static const _bodyTypes = <MeasurementType>[
    MeasurementType.weight,
    MeasurementType.bodyFat,
    MeasurementType.muscleMass,
    MeasurementType.waistCircumference,
    MeasurementType.hipCircumference,
  ];

  static String? _measurement(HealthMeasurement? value) =>
      value == null ? null : '${metricValue(value)} ${value.unit}';
  static String _source(HealthMeasurement? value) => value == null
      ? 'Unavailable'
      : '${value.source.name} · ${DateFormat.yMMMd().format(value.recordedAt)}';
  static String? _profileValue(String? value, String unit) =>
      value == null || value.isEmpty ? null : '$value $unit';
  static Future<void> _openEditor(BuildContext context, MeasurementType type) =>
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => MeasurementEditor(initialType: type),
        ),
      );
}

class _WeightProgress extends StatelessWidget {
  const _WeightProgress({required this.weight, required this.target});
  final HealthMeasurement? weight;
  final double? target;
  @override
  Widget build(BuildContext context) {
    final difference = weight == null || target == null
        ? null
        : weight!.value - target!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          children: [
            const Icon(Icons.monitor_weight_outlined, size: 42),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'WEIGHT PROGRESS',
                    style: TextStyle(fontSize: 10, letterSpacing: 1.4),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    weight == null
                        ? 'No weight data'
                        : '${weight!.value.toStringAsFixed(1)} kg',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  Text(
                    target == null
                        ? 'Set your target in Profile'
                        : difference == null
                        ? 'Target ${target!.toStringAsFixed(1)} kg'
                        : '${difference.abs().toStringAsFixed(1)} kg ${difference > 0 ? 'above' : 'below'} target',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BodyMetric extends StatelessWidget {
  const _BodyMetric(this.label, this.value, this.detail);
  final String label;
  final String? value;
  final String detail;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          FittedBox(
            child: Text(
              value ?? 'Unavailable',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            detail,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}
