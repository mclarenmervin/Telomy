import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../journal/providers/wellness_provider.dart';
import '../data/correlation_service.dart';

class CorrelationsScreen extends ConsumerStatefulWidget {
  const CorrelationsScreen({super.key});
  @override
  ConsumerState<CorrelationsScreen> createState() => _CorrelationsScreenState();
}

class _CorrelationsScreenState extends ConsumerState<CorrelationsScreen> {
  int days = 90;
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(wellnessProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Correlations', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text(
          'Patterns between health signals recorded on the same days.',
        ),
        const SizedBox(height: 18),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 30, label: Text('30 days')),
            ButtonSegment(value: 60, label: Text('60 days')),
            ButtonSegment(value: 90, label: Text('90 days')),
          ],
          selected: {days},
          onSelectionChanged: (value) => setState(() => days = value.first),
        ),
        const SizedBox(height: 22),
        ...state.when(
          loading: () => [const LinearProgressIndicator()],
          error: (_, _) => [
            TextButton(
              onPressed: () => ref.invalidate(wellnessProvider),
              child: const Text('Unable to calculate correlations. Retry'),
            ),
          ],
          data: (data) {
            final results = const CorrelationService().calculate(
              data,
              days: days,
            );
            return [
              if (results.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(22),
                    child: Text(
                      'At least five matching days with varied values are needed before a pattern can be calculated.',
                    ),
                  ),
                ),
              for (final result in results.take(12))
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${result.first} & ${result.second}',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            Text(result.coefficient.toStringAsFixed(2)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        LinearProgressIndicator(
                          value: result.coefficient.abs(),
                          color: result.coefficient >= 0
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.tertiary,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${result.strength} pattern · ${result.direction} · ${result.sampleDays} matching days',
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: Text(
                    'Correlation shows that two recorded values changed together. It does not show that one caused the other. Missing records, timing, medication, illness, and other factors may affect these patterns.',
                  ),
                ),
              ),
            ];
          },
        ),
      ],
    );
  }
}
