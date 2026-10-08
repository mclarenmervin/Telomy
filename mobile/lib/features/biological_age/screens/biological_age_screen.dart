import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/biological_age_view.dart';
import '../models/epigenetic_clock.dart';
import '../providers/biological_age_provider.dart';

/// Biological age: one number we compute, and any number of clocks we do not.
///
/// This screen renders and nothing else. The five-factor heuristic that used to
/// live behind it -- resting heart rate over 8, sleep against 7.5 hours, a BMI
/// term -- is gone rather than demoted: readiness keeps a labelled offline
/// estimate because the phone holds the readings it needs, and a biological age
/// has no equivalent. It comes from blood chemistry the phone cannot model, on
/// coefficients the app does not carry.
class BiologicalAgeScreen extends ConsumerWidget {
  const BiologicalAgeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final age = ref.watch(biologicalAgeProvider);
    final clocks = ref.watch(epigeneticClocksProvider);
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Biological age', style: theme.textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text(
          'Calculated on the server from the lab results you have confirmed, '
          'using a published model.',
        ),
        const SizedBox(height: 20),
        switch (age) {
          // A value we already have outranks a refresh in progress: replacing
          // the card with a spinner would make the number flicker away on every
          // rebuild.
          AsyncValue(:final value?) => _AgeCard(value),
          AsyncError() => const _Problem(
              'Your biological age could not be loaded.',
            ),
          _ => const LinearProgressIndicator(),
        },
        if (age.asData?.value case final view?)
          if (view.drivers.isNotEmpty) ...[
            const SizedBox(height: 14),
            _Drivers(view),
          ],
        const SizedBox(height: 14),
        switch (clocks) {
          AsyncValue(:final value?) => _Clocks(value),
          _ => const SizedBox.shrink(),
        },
      ],
    );
  }
}

class _AgeCard extends StatelessWidget {
  const _AgeCard(this.view);
  final BiologicalAgeView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (view.hasValue)
              Text(
                // One decimal, as the server computed it. Rounding to a whole
                // number here would disagree with the agent and the API.
                '${view.exactValue!.toStringAsFixed(1)} years',
                style: theme.textTheme.displaySmall,
              )
            else
              // Never a figure, never a dash that could read as one. The
              // sentence is the content in this state.
              Text(
                'Not yet available',
                style: theme.textTheme.titleLarge
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            const SizedBox(height: 10),
            Text(messageFor(view.state), style: theme.textTheme.bodyMedium),
            if (view.state == BiologicalAgeState.needsLabs &&
                view.missingMarkers.isNotEmpty) ...[
              const SizedBox(height: 12),
              _MissingMarkers(view),
            ],
            if (view.asOf case final asOf? when view.hasValue) ...[
              const SizedBox(height: 12),
              Text(
                // Whose day this is matters. The sample date, not the day the
                // sweep ran and not today.
                'From the blood drawn on ${DateFormat('d MMMM y').format(asOf)}.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
            if (view.modelVersion case final model? when view.hasValue)
              Text(
                'Model $model · ranges ${view.rangesVersion ?? 'unknown'}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
          ],
        ),
      ),
    );
  }
}

/// What to go and ask for, named. "We need a few more results" on its own is
/// not something anyone can act on.
class _MissingMarkers extends StatelessWidget {
  const _MissingMarkers(this.view);
  final BiologicalAgeView view;

  static const _reasons = {
    'wrong_context': 'we need a fasting sample',
    'censored': 'the lab could not measure it exactly',
    'qualitative': 'the result was not a number',
    'no_collection_date': 'we do not know when it was taken',
    'outside_critical_range': 'the value needs checking first',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final marker in view.missingMarkers)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              switch (_reasons[view.reasonFor(marker)]) {
                final reason? => '· ${_name(marker)} — $reason',
                _ => '· ${_name(marker)}',
              },
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  static String _name(String marker) =>
      marker.replaceAll('_', ' ').replaceFirstMapped(
            RegExp('^.'),
            (m) => m[0]!.toUpperCase(),
          );
}

class _Drivers extends StatelessWidget {
  const _Drivers(this.view);
  final BiologicalAgeView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Largest contribution first: the point of this list is which marker is
    // doing the most, in either direction.
    final drivers = [...view.drivers]
      ..sort((a, b) => b.score.abs().compareTo(a.score.abs()));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('What moves it', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              // These do not add up to the difference between the age above and
              // your real age, and saying so is cheaper than the support
              // conversation. PhenoAge is anchored on the population average,
              // which is well short of optimal -- so a panel a little above
              // optimal on every marker shows all-positive figures here and
              // still lands below chronological age.
              'How far each marker sits from an optimal value, in years. These '
              'are not a breakdown of the age above.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 12),
            for (final driver in drivers)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_MissingMarkers._name(driver.name)),
                          Text(
                            driver.detail,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.outline),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${driver.score >= 0 ? '+' : ''}'
                      '${driver.score.toStringAsFixed(1)}y',
                      style: theme.textTheme.titleMedium,
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

/// Other people's clocks, kept visibly apart from ours.
class _Clocks extends StatelessWidget {
  const _Clocks(this.clocks);
  final List<EpigeneticClock> clocks;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Epigenetic clocks', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              // Said once, clearly, rather than implied by a layout choice.
              clocks.isEmpty
                  ? 'If you have had an epigenetic test, you can record the '
                      'result here. We display these; we do not calculate them.'
                  : 'Measured by the providers named. We display these results '
                      'and do not calculate them, so they are not comparable '
                      'with the age above.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 12),
            for (final clock in clocks)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(clock.label),
                subtitle: Text(
                  '${clock.provider} · '
                  '${DateFormat('d MMM y').format(clock.collectedAt)}',
                ),
                trailing: Text(
                  clock.display,
                  style: theme.textTheme.titleMedium,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Text(message),
        ),
      );
}
