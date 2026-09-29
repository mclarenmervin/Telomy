import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/widgets/async_action.dart';
import '../../journal/providers/wellness_provider.dart';
import '../data/coach_service.dart';

class CoachScreen extends ConsumerWidget {
  const CoachScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(wellnessProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Daily coach', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text(
          'Small actions based on your goals and today’s recorded progress.',
        ),
        const SizedBox(height: 20),
        ...state.when(
          loading: () => [const LinearProgressIndicator()],
          error: (_, _) => [
            TextButton(
              onPressed: () => ref.invalidate(wellnessProvider),
              child: const Text('Unable to load coaching actions. Retry'),
            ),
          ],
          data: (data) {
            final service = const CoachService();
            final actions = service.actions(data, DateTime.now());
            final savedCount = actions
                .where((action) => service.saved(data, action))
                .length;
            return [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 72,
                        height: 72,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox.expand(
                              child: CircularProgressIndicator(
                                value: actions.isEmpty
                                    ? 1
                                    : savedCount / actions.length,
                                strokeWidth: 6,
                              ),
                            ),
                            Text('$savedCount/${actions.length}'),
                          ],
                        ),
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              actions.isEmpty
                                  ? 'Goals covered today'
                                  : 'Choose your focus',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              actions.isEmpty
                                  ? 'No current goal gaps were found in today’s data.'
                                  : 'Save useful actions to your personal plan.',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              for (final action in actions)
                _ActionCard(
                  action: action,
                  saved: service.saved(data, action),
                  onSave: () => runAction(
                    context,
                    () => ref
                        .read(wellnessProvider.notifier)
                        .saveEntry(service.planFor(action)),
                    success: 'Added to your plan',
                  ),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => context.push('/plans'),
                icon: const Icon(Icons.calendar_month_outlined),
                label: const Text('Open my plan'),
              ),
              const SizedBox(height: 18),
              const Text(
                'Suggestions use recorded data and personal goals. Adjust activity to how you feel and follow professional medical guidance.',
                style: TextStyle(fontSize: 12),
              ),
            ];
          },
        ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.action,
    required this.saved,
    required this.onSave,
  });
  final CoachAction action;
  final bool saved;
  final VoidCallback onSave;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Chip(label: Text(action.category)),
              const Spacer(),
              Text('${(action.completion * 100).round()}%'),
            ],
          ),
          Text(action.title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(action.detail),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: action.completion),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: saved ? null : onSave,
              icon: Icon(saved ? Icons.check : Icons.add),
              label: Text(saved ? 'In your plan' : 'Add to plan'),
            ),
          ),
        ],
      ),
    ),
  );
}
