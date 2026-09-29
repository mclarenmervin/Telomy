import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../health/models/health_measurement.dart';
import '../../journal/providers/wellness_provider.dart';

enum StressBand {
  rest('Rest', Color(0xFF2E8B76)),
  low('Low', Color(0xFF7EAE68)),
  medium('Medium', Color(0xFFB87914)),
  high('High', Color(0xFFC25A2E));

  const StressBand(this.label, this.color);
  final String label;
  final Color color;

  static StressBand fromValue(double value) {
    if (value < 25) return rest;
    if (value < 50) return low;
    if (value < 75) return medium;
    return high;
  }
}

class StressScreen extends ConsumerStatefulWidget {
  const StressScreen({super.key});
  @override
  ConsumerState<StressScreen> createState() => _StressScreenState();
}

class _StressScreenState extends ConsumerState<StressScreen> {
  DateTime date = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final readings = ref.watch(displayedMeasurementsProvider);
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Text('Stress', style: theme.textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text(
          'A wellness proxy from supported sensor or manual records. It is not a medical diagnosis.',
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
        readings.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) =>
              const _EmptyStress('Stress records could not be loaded.'),
          data: (all) {
            final values = _forDay(all, date);
            if (values.isEmpty) {
              return const _EmptyStress('No stress proxy data for this day.');
            }
            final average =
                values.fold(0.0, (sum, item) => sum + item.value) /
                values.length;
            return Column(
              children: [
                _StressHero(
                  value: average,
                  band: StressBand.fromValue(average),
                  count: values.length,
                ),
                const SizedBox(height: 12),
                _StressTimeline(values),
                const SizedBox(height: 12),
                _BandBreakdown(values),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        Text('Take a breathing break', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        const BreathingTimer(),
      ],
    );
  }

  List<HealthMeasurement> _forDay(List<HealthMeasurement> all, DateTime value) {
    final start = DateTime(value.year, value.month, value.day);
    final end = start.add(const Duration(days: 1));
    return all
        .where(
          (item) =>
              item.measurementType == MeasurementType.stress &&
              !item.recordedAt.isBefore(start) &&
              item.recordedAt.isBefore(end),
        )
        .toList()
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
  }

  bool get _isToday {
    final now = DateTime.now();
    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }
}

class _StressHero extends StatelessWidget {
  const _StressHero({
    required this.value,
    required this.band,
    required this.count,
  });
  final double value;
  final StressBand band;
  final int count;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          SizedBox(
            width: 78,
            height: 78,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: (value / 100).clamp(0, 1),
                    strokeWidth: 7,
                    color: band.color,
                  ),
                ),
                Text(
                  value.round().toString(),
                  style: Theme.of(context).textTheme.titleLarge,
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
                  'DAILY STRESS PROXY',
                  style: TextStyle(fontSize: 10, letterSpacing: 1.4),
                ),
                const SizedBox(height: 6),
                Text(
                  band.label,
                  style: Theme.of(
                    context,
                  ).textTheme.headlineMedium?.copyWith(color: band.color),
                ),
                Text('$count recorded observations · 0–100 scale'),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _StressTimeline extends StatelessWidget {
  const _StressTimeline(this.values);
  final List<HealthMeasurement> values;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Daily timeline', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          SizedBox(
            height: 120,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final value in values)
                  Expanded(
                    child: Tooltip(
                      message:
                          '${DateFormat.jm().format(value.recordedAt)} · ${value.value.round()} · ${value.source.name}',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: FractionallySizedBox(
                          heightFactor: (value.value / 100).clamp(0.03, 1),
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            decoration: BoxDecoration(
                              color: StressBand.fromValue(value.value).color,
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${DateFormat.jm().format(values.first.recordedAt)} — ${DateFormat.jm().format(values.last.recordedAt)}',
          ),
        ],
      ),
    ),
  );
}

class _BandBreakdown extends StatelessWidget {
  const _BandBreakdown(this.values);
  final List<HealthMeasurement> values;

  @override
  Widget build(BuildContext context) {
    final counts = {
      for (final band in StressBand.values)
        band: values
            .where((value) => StressBand.fromValue(value.value) == band)
            .length,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recorded states',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 14),
            for (final band in StressBand.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: band.color,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(band.label)),
                    Text('${counts[band]}'),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyStress extends StatelessWidget {
  const _EmptyStress(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(26),
      child: Column(
        children: [
          const Icon(Icons.waves, size: 42),
          const SizedBox(height: 14),
          Text(message),
        ],
      ),
    ),
  );
}

class BreathingTimer extends StatefulWidget {
  const BreathingTimer({super.key});
  @override
  State<BreathingTimer> createState() => _BreathingTimerState();
}

class _BreathingTimerState extends State<BreathingTimer> {
  int selectedMinutes = 3;
  int remaining = 180;
  int elapsed = 0;
  Timer? timer;

  bool get running => timer?.isActive ?? false;
  bool get inhaling => elapsed % 8 < 4;

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void toggle() {
    if (running) {
      timer?.cancel();
      setState(() {});
      return;
    }
    if (remaining == 0) reset();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (remaining <= 1) {
        timer?.cancel();
        setState(() {
          remaining = 0;
          elapsed++;
        });
      } else {
        setState(() {
          remaining--;
          elapsed++;
        });
      }
    });
    setState(() {});
  }

  void reset() {
    timer?.cancel();
    setState(() {
      remaining = selectedMinutes * 60;
      elapsed = 0;
    });
  }

  void choose(int minutes) {
    timer?.cancel();
    setState(() {
      selectedMinutes = minutes;
      remaining = minutes * 60;
      elapsed = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final seconds = remaining % 60;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          children: [
            Wrap(
              spacing: 8,
              children: [
                for (final minutes in const [1, 3, 5])
                  ChoiceChip(
                    label: Text('$minutes min'),
                    selected: selectedMinutes == minutes,
                    onSelected: running ? null : (_) => choose(minutes),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            AnimatedContainer(
              duration: const Duration(seconds: 1),
              curve: Curves.easeInOut,
              width: running ? (inhaling ? 150 : 100) : 112,
              height: running ? (inhaling ? 150 : 100) : 112,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.primaryContainer,
              ),
              alignment: Alignment.center,
              child: Text(
                running ? (inhaling ? 'Breathe in' : 'Breathe out') : 'Ready',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 22),
            Text(
              '${remaining ~/ 60}:${seconds.toString().padLeft(2, '0')}',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: toggle,
                  icon: Icon(running ? Icons.pause : Icons.play_arrow),
                  label: Text(
                    running
                        ? 'Pause'
                        : remaining == 0
                        ? 'Again'
                        : 'Start',
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(onPressed: reset, child: const Text('Reset')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
