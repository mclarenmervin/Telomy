import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../journal/providers/wellness_provider.dart';
import '../data/biological_age_service.dart';

class BiologicalAgeScreen extends ConsumerWidget {
  const BiologicalAgeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wellness = ref.watch(wellnessProvider);
    final measurements = ref.watch(displayedMeasurementsProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Biological age',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 8),
        const Text('A wellness estimate based on recent recorded signals.'),
        const SizedBox(height: 20),
        if (wellness.isLoading || measurements.isLoading)
          const LinearProgressIndicator(),
        if (wellness.hasError || measurements.hasError)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(22),
              child: Text('Biological-age data could not be loaded.'),
            ),
          ),
        if (wellness.asData case final data?)
          if (measurements.asData case final values?)
            Builder(
              builder: (context) {
                final service = const BiologicalAgeService();
                final result = service.calculate(
                  data: data.value,
                  measurements: values.value,
                  date: DateTime.now(),
                );
                return Column(
                  children: [
                    _AgeHero(result),
                    const SizedBox(height: 14),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Estimate factors',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 14),
                            for (final factor in result.factors)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: CircleAvatar(
                                  child: Icon(
                                    factor.adjustment <= 0
                                        ? Icons.trending_down
                                        : Icons.trending_up,
                                  ),
                                ),
                                title: Text(factor.name),
                                subtitle: Text(factor.detail),
                                trailing: Text(
                                  '${factor.adjustment > 0 ? '+' : ''}${factor.adjustment.toStringAsFixed(1)} y',
                                ),
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
                    const SizedBox(height: 12),
                    const Text(
                      'This estimate is not a clinical biological-age test and does not predict lifespan or disease.',
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

class _AgeHero extends StatelessWidget {
  const _AgeHero(this.result);
  final BiologicalAgeResult result;
  @override
  Widget build(BuildContext context) {
    final difference =
        result.estimatedAge == null || result.chronologicalAge == null
        ? null
        : result.estimatedAge! - result.chronologicalAge!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          children: [
            CircleAvatar(
              radius: 42,
              child: Text(
                result.estimatedAge?.toStringAsFixed(1) ?? '—',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.estimatedAge == null
                        ? 'More data needed'
                        : 'Estimated biological age',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text('Chronological age ${result.chronologicalAge ?? '—'}'),
                  if (difference != null)
                    Text(
                      '${difference > 0 ? '+' : ''}${difference.toStringAsFixed(1)} years difference',
                    ),
                  Text(
                    'Confidence ${((result.confidence ?? 0) * 100).round()}%',
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
