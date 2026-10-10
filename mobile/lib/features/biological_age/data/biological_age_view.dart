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

/// The nine markers PhenoAge takes, matching `biological_age.PHENOAGE_MARKERS`.
/// Held here so the screen can label and order them without the catalog, which
/// is server-side medical content the app does not carry.
const phenoAgeMarkers = [
  'albumin',
  'creatinine',
  'glucose_fasting',
  'hs_crp',
  'lymphocyte_percent',
  'mcv',
  'rdw',
  'alkaline_phosphatase',
  'wbc',
];

/// How each marker is printed on a lab report.
///
/// Deriving a label from the id gives "Rdw", "Mcv" and "Hs crp". These are
/// acronyms with a fixed printed form, and a user checking the screen against
/// their own PDF should be reading the same string on both.
///
/// The nine PhenoAge markers came first, for the biological-age screen. The
/// rest arrived with F5, whose clinical insights can name any marker the
/// catalog maps — a trend in ferritin or TSH reaches a screen now, and "Tsh"
/// is the same bug as "Rdw" with a different id.
///
/// Where this disagrees with the catalog's `name` it is deliberate. The server
/// spells out "Mean corpuscular volume"; a lab report prints "MCV", and the
/// user is comparing against the report rather than against our catalog.
const _markerLabels = {
  // PhenoAge
  'albumin': 'Albumin',
  'creatinine': 'Creatinine',
  'glucose_fasting': 'Fasting glucose',
  'hs_crp': 'hs-CRP',
  'lymphocyte_percent': 'Lymphocytes',
  'mcv': 'MCV',
  'rdw': 'RDW',
  'alkaline_phosphatase': 'Alkaline phosphatase',
  'wbc': 'WBC',
  // The rest of the catalog, for anything that can appear in an insight.
  'alt': 'ALT',
  'apob': 'Apolipoprotein B',
  'ast': 'AST',
  'cortisol_morning': 'Morning cortisol',
  'dhea_s': 'DHEA-S',
  'egfr': 'eGFR',
  'ferritin': 'Ferritin',
  'free_t3': 'Free T3',
  'free_t4': 'Free T4',
  'ggt': 'GGT',
  'haemoglobin': 'Haemoglobin',
  'hba1c': 'HbA1c',
  'hdl_cholesterol': 'HDL cholesterol',
  'homocysteine': 'Homocysteine',
  'igf_1': 'IGF-1',
  'insulin_fasting': 'Fasting insulin',
  'ldl_cholesterol': 'LDL cholesterol',
  'lipoprotein_a': 'Lipoprotein(a)',
  'magnesium': 'Magnesium',
  'triglycerides': 'Triglycerides',
  'tsh': 'TSH',
  'uric_acid': 'Uric acid',
  'vitamin_b12': 'Vitamin B12',
  'vitamin_d_25oh': 'Vitamin D (25-OH)',
};

/// A marker's printed name. An id the app has not heard of -- a marker added to
/// the catalog after this build shipped -- still renders as words rather than
/// as a database identifier.
String markerLabel(String marker) =>
    _markerLabels[marker] ??
    marker.replaceAll('_', ' ').replaceFirstMapped(
          RegExp('^.'),
          (m) => m[0]!.toUpperCase(),
        );
