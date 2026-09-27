import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../../core/config/supabase_config.dart';
import '../../journal/providers/wellness_provider.dart';
import '../providers/ring_provider.dart';

enum RingActivityType {
  running('Running', Icons.directions_run_rounded),
  walking('Walking', Icons.directions_walk_rounded),
  cycling('Cycling', Icons.directions_bike_rounded),
  swimming('Swimming', Icons.pool_rounded),
  strength('Strength training', Icons.fitness_center_rounded),
  yoga('Yoga', Icons.self_improvement_rounded),
  other('Other', Icons.sports_rounded);

  const RingActivityType(this.label, this.icon);
  final String label;
  final IconData icon;
}

class ActivitySessionScreen extends ConsumerStatefulWidget {
  const ActivitySessionScreen({super.key});
  @override
  ConsumerState<ActivitySessionScreen> createState() =>
      _ActivitySessionScreenState();
}

class _ActivitySessionScreenState extends ConsumerState<ActivitySessionScreen> {
  RingActivityType _type = RingActivityType.running;
  DateTime? _startedAt;
  Timer? _ticker;
  bool _busy = false;
  String? _error;
  final List<Map<String, dynamic>> _samples = [];

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final ring = ref.read(wellnessProvider).asData?.value.ring ?? {};
    if ((ring['id'] as String?) == null) {
      if (mounted) context.push('/add-ring');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(ringProvider.notifier).sync();
      if (!mounted) return;
      if (!ref.read(ringProvider).connected) {
        throw StateError('The ring did not connect.');
      }
      _samples.clear();
      _startedAt = DateTime.now();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final snapshot = ref.read(ringProvider).snapshot;
        final sample = <String, dynamic>{
          'recordedAt': DateTime.now().toUtc().toIso8601String(),
        };
        for (final key in const [
          'heartRate',
          'steps',
          'spo2',
          'stress',
          'hrv',
          'battery',
          'firmware',
        ]) {
          if (snapshot[key] != null) sample[key] = snapshot[key];
        }
        _samples.add(sample);
        setState(() {});
      });
      setState(() => _busy = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error is StateError
            ? error.message
            : 'Could not connect to the ring for this activity.';
      });
    }
  }

  Future<void> _stop() async {
    final started = _startedAt;
    if (started == null || _busy) return;
    final ended = DateTime.now();
    _ticker?.cancel();
    setState(() => _busy = true);
    try {
      if (!SupabaseConfig.configured) {
        throw StateError('Cloud storage is not configured for this build.');
      }
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) throw StateError('Sign in before saving an activity.');
      final latest = ref.read(ringProvider).snapshot;
      final summary = <String, dynamic>{
        for (final key in const [
          'heartRate',
          'steps',
          'spo2',
          'stress',
          'hrv',
          'battery',
          'firmware',
        ])
          if (latest[key] != null) key: latest[key],
      };
      await Supabase.instance.client.from('activity_sessions').insert({
        'id': const Uuid().v4(),
        'user_id': user.id,
        'activity_type': _type.name,
        'started_at': started.toUtc().toIso8601String(),
        'ended_at': ended.toUtc().toIso8601String(),
        'duration_seconds': ended.difference(started).inSeconds,
        'summary': summary,
        'samples': _samples,
      });
      if (!mounted) return;
      setState(() {
        _startedAt = null;
        _samples.clear();
        _busy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Activity saved to your health history.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error is StateError
            ? error.message
            : 'Activity could not be saved.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _startedAt != null;
    final snapshot = ref.watch(ringProvider).snapshot;
    final elapsed = running
        ? DateTime.now().difference(_startedAt!)
        : Duration.zero;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Ring activity')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          Text('Track an activity', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(
            running
                ? 'Your ring is capturing measurements every second.'
                : 'Choose an activity, then start a ring-powered session.',
          ),
          const SizedBox(height: 22),
          if (!running)
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final value in RingActivityType.values)
                  ChoiceChip(
                    avatar: Icon(value.icon, size: 18),
                    label: Text(value.label),
                    selected: value == _type,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _type = value),
                  ),
              ],
            ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                children: [
                  Icon(
                    running ? Icons.sensors : _type.icon,
                    size: 58,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    running ? _type.label : 'Ready to begin',
                    style: theme.textTheme.titleLarge,
                  ),
                  if (running) ...[
                    const SizedBox(height: 6),
                    Text(
                      _formatDuration(elapsed),
                      style: theme.textTheme.displaySmall,
                    ),
                    Text('${_samples.length} samples captured'),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _busy ? null : (running ? _stop : _start),
                    icon: Icon(
                      running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    ),
                    label: Text(
                      _busy
                          ? 'Connecting…'
                          : running
                          ? 'Stop and save'
                          : 'Start activity',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (running) _LiveMetrics(snapshot),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }

  String _formatDuration(Duration value) =>
      '${value.inHours.toString().padLeft(2, '0')}:${(value.inMinutes % 60).toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
}

class _LiveMetrics extends StatelessWidget {
  const _LiveMetrics(this.snapshot);
  final Map<String, dynamic> snapshot;
  @override
  Widget build(BuildContext context) => GridView.count(
    crossAxisCount: 2,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    crossAxisSpacing: 10,
    mainAxisSpacing: 10,
    childAspectRatio: 1.7,
    children: [
      _Metric('Heart rate', snapshot['heartRate'], 'BPM'),
      _Metric('Steps', snapshot['steps'], ''),
      _Metric('Blood oxygen', snapshot['spo2'], '%'),
      _Metric('Stress', snapshot['stress'], ''),
      _Metric('HRV', snapshot['hrv'], 'ms'),
      _Metric('Battery', snapshot['battery'], '%'),
    ],
  );
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, this.unit);
  final String label;
  final dynamic value;
  final String unit;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const Spacer(),
          Text(
            '${value ?? '—'} $unit',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ],
      ),
    ),
  );
}
