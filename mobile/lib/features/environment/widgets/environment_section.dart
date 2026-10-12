import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/vocabulary.dart';
import '../data/coarse_places.dart';
import '../data/environment_repository.dart';
import '../models/environment_snapshot.dart';
import '../providers/environment_provider.dart';
import 'location_picker.dart';

/// The air and the sun where this person said they were.
///
/// Above the free-text environment form, which has always asked people to
/// type an AQI in by hand and then did nothing with it.
///
/// Two things this is careful about. The location is a city and the screen
/// says so, every time, rather than once at setup — somebody coming back in
/// six months should be able to see what they shared without digging. And
/// it never joins the air to the person: a day's AQI sits beside a day, and
/// what it did to them is a claim nobody has reviewed.
class EnvironmentSection extends ConsumerWidget {
  const EnvironmentSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final place = ref.watch(chosenPlaceProvider);

    return Column(
      key: const Key('environment-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Air and sun where you are', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          place == null
              ? 'Tell us roughly where you are and we will look up the air '
                  'quality and UV for that area each day.'
              : 'Looked up each day for ${place.label}.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (place == null)
          _SetLocation(onPick: () => _choose(context, ref))
        else
          _Conditions(place: place, onChange: () => _choose(context, ref),
              onClear: () => setCoarseLocation(ref, null)),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
      ],
    );
  }

  Future<void> _choose(BuildContext context, WidgetRef ref) async {
    final picked = await pickCoarsePlace(context);
    if (picked == null) return;
    await setCoarseLocation(ref, picked);
  }
}

class _SetLocation extends StatelessWidget {
  const _SetLocation({required this.onPick});

  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('environment-no-location'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'We do not know where you are, and we will not ask your phone. '
              'Pick a city instead — that is all the precision this needs.',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('environment-set-location'),
              onPressed: onPick,
              icon: const Icon(Icons.location_city_outlined),
              label: const Text('Choose your city'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Conditions extends ConsumerWidget {
  const _Conditions({
    required this.place,
    required this.onChange,
    required this.onClear,
  });

  final CoarsePlace place;
  final VoidCallback onChange;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(environmentProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...days.when(
          loading: () => [const Loading('Looking up the air and the sun…')],
          error: (error, _) => [
            ErrorState(
              message: error is EnvironmentUnavailable
                  ? error.message
                  : 'This could not be looked up just now.',
              onRetry: () => ref.invalidate(environmentProvider),
            ),
          ],
          data: (items) => items.isEmpty
              ? [
                  const Empty(
                    key: Key('environment-waiting'),
                    title: 'Nothing yet',
                    body: 'The first day arrives overnight — we look up a '
                        'whole day once it has finished, because half a day '
                        'of air quality is not a day.',
                    tone: EmptyTone.waiting,
                  ),
                ]
              : [for (final day in items.take(7)) _DayCard(day: day)],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton(
              key: const Key('environment-change-location'),
              onPressed: onChange,
              child: const Text('Change city'),
            ),
            TextButton(
              key: const Key('environment-clear-location'),
              onPressed: onClear,
              child: const Text('Stop looking this up'),
            ),
          ],
        ),
      ],
    );
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({required this.day});

  final EnvironmentSnapshot day;

  @override
  Widget build(BuildContext context) {
    final when = day.observedOn == null
        ? ''
        : DateFormat('EEE d MMM').format(day.observedOn!);

    // A day built from eighteen of twenty-four hours is not a day, and
    // whoever reads it should know. That was its own sentence before F9 and
    // is now the basis of the confidence: a part-day is `estimated`, a whole
    // one is `measured`.
    final partial = day.isPartialDay;
    final prov = Prov(
      // Named every time. "The AQI was 181" is a claim somebody else made,
      // and the user is entitled to know who made it.
      source: day.provider,
      when: day.observedOn,
      confidence: partial ? Confidence.estimated : Confidence.measured,
      basis: '${day.hoursObserved} of 24 hours observed',
    );

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          T(when, v: TextVariant.h3),
          const SizedBox(height: AppSpacing.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (day.usAqiMax != null)
                Expanded(
                  child: Stat(
                    label: 'Air quality',
                    // The peak, because three hours at 180 is the thing
                    // worth saying about the day.
                    value: day.usAqiMax!.round().toString(),
                    // The published definition of the scale, not a verdict
                    // about this person. The US AQI IS its breakpoints.
                    status: day.usAqiBand == null
                        ? null
                        : StatusChip(_band(day.usAqiBand!),
                            label: day.usAqiBand!),
                  ),
                ),
              if (day.uvIndexMax != null)
                Expanded(
                  child: Stat(
                    label: 'UV peak',
                    value: day.uvIndexMax!.toStringAsFixed(1),
                    status: day.uvBand == null
                        ? null
                        : StatusChip(_band(day.uvBand!), label: day.uvBand!),
                  ),
                ),
            ],
          ),
          // One Prov for the card rather than one per reading: both figures
          // come from the same provider for the same day with the same hours
          // behind them, and repeating it twice would be noise.
          prov,
        ],
      ),
    );
  }

  /// Which status token a published band maps onto.
  ///
  /// The bands are the scale's own words and are rendered verbatim — this
  /// only picks a colour for them. Anything unrecognised is `typical`, which
  /// is the quiet one: a new breakpoint label should not arrive on screen in
  /// the colour of "out of range" because nobody updated this.
  AppStatus _band(String band) => switch (band) {
        'good' || 'low' => AppStatus.optimal,
        'moderate' => AppStatus.inRange,
        'high' => AppStatus.riskVariant,
        'unhealthy for sensitive groups' ||
        'unhealthy' ||
        'very high' =>
          AppStatus.outOfRange,
        'very unhealthy' || 'hazardous' || 'extreme' => AppStatus.rejected,
        _ => AppStatus.typical,
      };
}
