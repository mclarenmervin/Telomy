import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../journal/providers/wellness_provider.dart';
import '../data/readiness_service.dart';

class ReadinessScreen extends ConsumerStatefulWidget {
  const ReadinessScreen({super.key});
  @override
  ConsumerState<ReadinessScreen> createState() => _ReadinessScreenState();
}

class _ReadinessScreenState extends ConsumerState<ReadinessScreen> {
  DateTime date = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final measurements = ref.watch(displayedMeasurementsProvider);
    final data = ref.watch(wellnessProvider).asData?.value;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Text('Recovery & readiness', style: theme.textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text(
          'An estimate based on your available baseline and recent records.',
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: () =>
                  setState(() => date = date.subtract(const Duration(days: 1))),
              icon: const Icon(Icons.chevron_left),
            ),
            Text(
              DateFormat('EEE, d MMM').format(date),
              style: theme.textTheme.titleMedium,
            ),
            IconButton(
              onPressed: _isToday
                  ? null
                  : () => setState(
                      () => date = date.add(const Duration(days: 1)),
                    ),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 14),
        measurements.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Readiness data could not be loaded.'),
            ),
          ),
          data: (values) {
            final result = const ReadinessService().calculate(
              measurements: values,
              date: date,
              sleepGoal: data?.goal('sleepGoal', 8) ?? 8,
              activityGoal: data?.goal('activityGoal', 30) ?? 30,
            );
            return Column(
              children: [
                _ReadinessHero(result),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Score drivers',
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 14),
                        if (result.drivers.isEmpty)
                          const Text(
                            'No score drivers are available for this date.',
                          ),
                        for (final driver in result.drivers)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(child: Text(driver.name)),
                                    Text(driver.score.round().toString()),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                LinearProgressIndicator(
                                  value: driver.score / 100,
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  driver.detail,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Data coverage',
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          result.missingInputs.isEmpty
                              ? 'All configured inputs are available.'
                              : 'Missing: ${result.missingInputs.join(', ')}',
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Model ${result.modelVersion}',
                          style: theme.textTheme.bodySmall,
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

  bool get _isToday {
    final now = DateTime.now();
    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }
}

class _ReadinessHero extends StatelessWidget {
  const _ReadinessHero(this.result);
  final ReadinessResult result;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          SizedBox(
            width: 82,
            height: 82,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: (result.score ?? 0) / 100,
                    strokeWidth: 7,
                  ),
                ),
                Text(
                  result.score?.toString() ?? '—',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'READINESS ESTIMATE',
                  style: TextStyle(fontSize: 10, letterSpacing: 1.4),
                ),
                const SizedBox(height: 8),
                Text(result.recommendation),
                const SizedBox(height: 8),
                const Text(
                  'Use how you feel alongside this estimate. It is not medical advice.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
