import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../journal/providers/wellness_provider.dart';
import '../services/longi_score_service.dart';

class LongiScoreScreen extends ConsumerWidget {
  const LongiScoreScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wellness = ref.watch(wellnessProvider);
    final measurements = ref.watch(displayedMeasurementsProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('LongiScore', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text(
          'A daily summary of the health signals available to Telomy.',
        ),
        const SizedBox(height: 20),
        if (wellness.isLoading || measurements.isLoading)
          const LinearProgressIndicator(),
        if (wellness.hasError || measurements.hasError)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(22),
              child: Text('LongiScore data could not be loaded.'),
            ),
          ),
        if (wellness.asData case final wellnessData?)
          if (measurements.asData case final measurementData?)
            Builder(
              builder: (context) {
                final service = const LongiScoreService();
                final result = service.calculate(
                  data: wellnessData.value,
                  measurements: measurementData.value,
                  date: DateTime.now(),
                );
                final history = [
                  for (var offset = 6; offset >= 0; offset--)
                    (
                      DateTime.now().subtract(Duration(days: offset)),
                      service.calculate(
                        data: wellnessData.value,
                        measurements: measurementData.value,
                        date: DateTime.now().subtract(Duration(days: offset)),
                      ),
                    ),
                ];
                return Column(
                  children: [
                    _ScoreHero(result),
                    const SizedBox(height: 14),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Seven-day history',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 16),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                for (final item in history)
                                  Expanded(
                                    child: _ScoreBar(
                                      label: DateFormat.E().format(item.$1),
                                      value: item.$2.value,
                                    ),
                                  ),
                              ],
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
                              'Score components',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 14),
                            for (final component in result.components)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(child: Text(component.name)),
                                        Text('${component.score.round()}'),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    LinearProgressIndicator(
                                      value: component.score / 100,
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      component.detail,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            if (result.components.isEmpty)
                              const Text(
                                'No score components are available today.',
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.info_outline),
                        title: Text('Model ${result.version}'),
                        subtitle: Text(
                          result.missingInputs.isEmpty
                              ? 'All configured inputs are available.'
                              : 'Missing: ${result.missingInputs.join(', ')}',
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'LongiScore is a wellness summary, not a diagnosis or medical risk score.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                );
              },
            ),
      ],
    );
  }
}

class _ScoreHero extends StatelessWidget {
  const _ScoreHero(this.result);
  final LongiScoreResult result;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          SizedBox(
            width: 94,
            height: 94,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: (result.value ?? 0) / 100,
                    strokeWidth: 8,
                  ),
                ),
                Text(
                  result.value?.toString() ?? '—',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.value == null
                      ? 'More data needed'
                      : _label(result.value!),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text('Data coverage ${(result.coverage * 100).round()}%'),
                Text('Confidence ${(result.confidence * 100).round()}%'),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  static String _label(int value) => value >= 80
      ? 'Strong daily signals'
      : value >= 60
      ? 'Balanced daily signals'
      : 'Signals need attention';
}

class _ScoreBar extends StatelessWidget {
  const _ScoreBar({required this.label, required this.value});
  final String label;
  final int? value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: Column(
      children: [
        Text(value?.toString() ?? '—', style: const TextStyle(fontSize: 11)),
        const SizedBox(height: 5),
        Container(
          height: value == null ? 4 : 12 + value! * .65,
          decoration: BoxDecoration(
            color: value == null
                ? Theme.of(context).colorScheme.outlineVariant
                : Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 10)),
      ],
    ),
  );
}
