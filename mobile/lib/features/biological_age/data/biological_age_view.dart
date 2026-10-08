import 'package:flutter/foundation.dart';

import '../../scores/models/score_snapshot.dart';

/// Turns a server snapshot into what the screen may say.
///
/// There is **no calculation here and no offline fallback**, which is the one
/// way this file differs from readiness. Readiness keeps a frozen local
/// estimate for when the phone is on a train, clearly labelled as one. A
/// biological age gets no such thing: it is computed from lab values the phone
/// has no business modelling, on a published model whose coefficients the app
/// does not carry, and an "offline estimate" of someone's biological age is a
/// sentence with no defensible meaning. The old five-factor heuristic that used
/// to live here produced exactly that.
///
/// The more interesting half of this file is the absence of a number. A null
/// value arrives for four different reasons and they call for four different
/// sentences -- one of them is "we are not going to tell you", which has to be
/// said plainly rather than dressed up as "not enough data".
enum BiologicalAgeState {
  /// The server computed one and we may show it.
  ready,

  /// Computed, and withheld: `biomarkers.v1.yaml` has not been reviewed by a
  /// clinician. The gate lives on the server, which never writes the number; by
  /// the time the app sees the row there is nothing to leak.
  awaitingClinicalReview,

  /// The model does not apply to this person at all -- pregnancy shifts
  /// reference ranges substantially, and adult models do not transfer to a
  /// minor. Distinct from a gap, because there is nothing to go and collect.
  notApplicable,

  /// We need something from the profile: a date of birth, most likely.
  needsProfile,

  /// We need lab values, named so the user can ask for them.
  needsLabs,

  /// No snapshot exists. We have not looked yet, which is not the same as
  /// having looked and found nothing.
  notComputed,
}

/// The refusals `subject.py` emits. Not markers, and not something a blood test
/// fixes, so they must not be rendered in a list of tests to go and get.
const _profileRefusals = {'date_of_birth', 'implausible_date_of_birth'};
const _notApplicableRefusals = {'pregnancy', 'under_minimum_age'};
const _clinicalReview = 'clinical_review';

@immutable
class BiologicalAgeView {
  const BiologicalAgeView({
    required this.state,
    this.exactValue,
    this.asOf,
    this.modelVersion,
    this.rangesVersion,
    this.drivers = const [],
    this.missingMarkers = const [],
    this.reasons = const {},
  });

  final BiologicalAgeState state;

  /// Years, with the fraction the server sent. Null in every state but [ready].
  final double? exactValue;

  /// The date the blood was drawn -- not the date the score was computed and
  /// not today. A biological age is a property of a draw.
  final DateTime? asOf;

  final String? modelVersion;
  final String? rangesVersion;
  final List<ScoreDriver> drivers;

  /// Markers we need, without the `:reason` suffix the server attaches.
  final List<String> missingMarkers;

  /// marker -> why the rows we had were unusable (`wrong_context`, `censored`).
  final Map<String, String> reasons;

  bool get hasValue => exactValue != null;

  String? reasonFor(String marker) => reasons[marker];

  static BiologicalAgeView of(ScoreSnapshot? snapshot) {
    if (snapshot == null) {
      return const BiologicalAgeView(state: BiologicalAgeState.notComputed);
    }

    if (snapshot.exactValue != null) {
      return BiologicalAgeView(
        state: BiologicalAgeState.ready,
        exactValue: snapshot.exactValue,
        asOf: snapshot.asOf,
        modelVersion: snapshot.modelVersion,
        rangesVersion: snapshot.rangesVersion,
        drivers: snapshot.drivers,
      );
    }

    final missing = snapshot.missingInputs;
    final markers = <String>[];
    final reasons = <String, String>{};
    for (final entry in missing) {
      if (entry == _clinicalReview ||
          _profileRefusals.contains(entry) ||
          _notApplicableRefusals.contains(entry)) {
        continue;
      }
      // `marker` or `marker:reason`.
      final split = entry.indexOf(':');
      final marker = split < 0 ? entry : entry.substring(0, split);
      markers.add(marker);
      if (split >= 0) reasons[marker] = entry.substring(split + 1);
    }
    markers.sort();

    // Order is a product decision, not an accident.
    //
    // Awaiting review comes first because it is the binding blocker: no panel,
    // however complete, produces a number while it holds, so naming a missing
    // marker would send someone for a blood test that cannot help.
    //
    // Not-applicable comes next because there is nothing to collect at all.
    //
    // A profile gap beats a lab gap because fixing it is one tap rather than a
    // blood draw.
    final state = missing.contains(_clinicalReview)
        ? BiologicalAgeState.awaitingClinicalReview
        : missing.any(_notApplicableRefusals.contains)
            ? BiologicalAgeState.notApplicable
            : missing.any(_profileRefusals.contains)
                ? BiologicalAgeState.needsProfile
                : markers.isNotEmpty
                    ? BiologicalAgeState.needsLabs
                    : BiologicalAgeState.notComputed;

    return BiologicalAgeView(
      state: state,
      asOf: snapshot.asOf,
      modelVersion: snapshot.modelVersion,
      rangesVersion: snapshot.rangesVersion,
      missingMarkers: markers,
      reasons: reasons,
    );
  }
}

/// Only [BiologicalAgeState.ready] ever shows a number. Asserted in a test
/// rather than left to each call site, because a placeholder that renders as a
/// figure -- a dash that looks like a zero, "Learning" where an age goes -- is
/// the failure this whole state machine exists to prevent.
bool offersAValue(BiologicalAgeState state) =>
    state == BiologicalAgeState.ready;

/// What the user is told, per state. Deliberately free of digits: a sentence
/// about a missing number must not contain something that could be read as one.
String messageFor(BiologicalAgeState state) => switch (state) {
      BiologicalAgeState.ready =>
        'Calculated from your confirmed lab results on a published model.',
      BiologicalAgeState.awaitingClinicalReview =>
        'We can calculate this from your results, but our reference ranges are '
            'still being reviewed by a clinician. Until that is done we will '
            'not put an age in front of you.',
      BiologicalAgeState.notApplicable =>
        'This measure does not apply right now, so we are not estimating it.',
      BiologicalAgeState.needsProfile =>
        'Add your date of birth and we can work this out.',
      BiologicalAgeState.needsLabs =>
        'We need a few more blood results before this can be worked out.',
      BiologicalAgeState.notComputed =>
        'Upload a blood report and we will work this out from it.',
    };
