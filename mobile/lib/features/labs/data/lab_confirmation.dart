import '../models/biomarker_result.dart';
import '../models/lab_upload.dart';

/// What the user decided about one extracted value.
enum ResultAction { confirm, correct, reject }

class ResultDecision {
  const ResultDecision(this.action, {this.value, this.unit});

  final ResultAction action;
  final double? value;
  final String? unit;

  /// A correction with no number is not a decision yet. Sending it would be a
  /// 422 the user cannot interpret.
  bool get isComplete => action != ResultAction.correct || value != null;

  String get wireAction => switch (action) {
        ResultAction.confirm => 'confirm',
        ResultAction.correct => 'correct',
        ResultAction.reject => 'reject',
      };
}

/// The confirmation screen's rules, kept out of widget state so they can be
/// tested.
///
/// The gateway refuses a confirmation that is incomplete, names someone else or
/// carries no collection date. The screen has to refuse it first *and say why*,
/// or the user meets an error they have no way to interpret. These are the same
/// rules, stated once on this side.
class ConfirmationDraft {
  ConfirmationDraft({required this.upload, required this.results});

  final LabUpload upload;
  final List<BiomarkerResult> results;

  final Map<String, ResultDecision> decisions = {};

  /// Supplied by the user when we could not read one confidently.
  DateTime? collectedAt;

  /// Null means not answered yet, which is not the same as `false`.
  bool? patientIsMe;

  void confirm(String resultId) =>
      decisions[resultId] = const ResultDecision(ResultAction.confirm);

  void reject(String resultId) =>
      decisions[resultId] = const ResultDecision(ResultAction.reject);

  void correct(String resultId, {double? value, String? unit}) =>
      decisions[resultId] = ResultDecision(ResultAction.correct, value: value, unit: unit);

  void clear(String resultId) => decisions.remove(resultId);

  ResultDecision? decisionFor(String resultId) => decisions[resultId];

  /// Results with no decision yet.
  ///
  /// Every one needs an answer: a silent partial confirmation leaves rows
  /// nobody looks at again — invisible to every score and invisible to the user.
  List<BiomarkerResult> get undecided =>
      results.where((r) => !decisions.containsKey(r.id)).toList();

  List<BiomarkerResult> get incompleteCorrections => results
      .where((r) => decisions[r.id] != null && !decisions[r.id]!.isComplete)
      .toList();

  /// The report names someone, and the user has not yet said it is them.
  bool get needsPatientConfirmation => upload.patientName != null;

  /// We are not confident about the collection date, and the user has not
  /// supplied one. Trending uses this date; guessing puts an old panel on
  /// today's chart.
  bool get needsCollectionDate =>
      upload.collectionDateIsUncertain && collectedAt == null;

  bool get _collectionDateIsInTheFuture {
    final supplied = collectedAt;
    if (supplied == null) return false;
    return supplied.isAfter(DateTime.now().add(const Duration(days: 1)));
  }

  /// Why this cannot be submitted, in words a person can act on.
  List<String> get blockers {
    final reasons = <String>[];

    if (!upload.isAwaitingConfirmation) {
      reasons.add(
        upload.isConfirmed
            ? 'This report has already been confirmed.'
            : 'This report is not ready to confirm yet.',
      );
    }
    if (undecided.isNotEmpty) {
      final count = undecided.length;
      reasons.add('$count value${count == 1 ? '' : 's'} still need a decision.');
    }
    if (incompleteCorrections.isNotEmpty) {
      reasons.add('Enter a value for the results you are correcting.');
    }
    if (needsPatientConfirmation && patientIsMe == null) {
      reasons.add('Confirm whether this report is yours.');
    }
    if (needsPatientConfirmation && patientIsMe == false) {
      reasons.add(
        'This report names ${upload.patientName}. We can only add your own '
        'results to your record.',
      );
    }
    if (needsCollectionDate) {
      reasons.add('Tell us when the sample was collected.');
    }
    if (_collectionDateIsInTheFuture) {
      reasons.add('The collection date cannot be in the future.');
    }
    return reasons;
  }

  bool get canSubmit => blockers.isEmpty;

  /// The body the confirm endpoint expects.
  ///
  /// `collected_at` is omitted when the server already has a confident date, so
  /// opening the screen and confirming cannot overwrite a good extracted date
  /// with whatever the picker happened to default to.
  Map<String, dynamic> toRequest() {
    final body = <String, dynamic>{
      'decisions': [
        for (final entry in decisions.entries)
          {
            'result_id': entry.key,
            'action': entry.value.wireAction,
            if (entry.value.action == ResultAction.correct) 'value': entry.value.value,
            if (entry.value.action == ResultAction.correct && entry.value.unit != null)
              'unit': entry.value.unit,
          },
      ],
    };
    if (needsPatientConfirmation) body['patient_is_me'] = patientIsMe;
    final supplied = collectedAt;
    if (supplied != null) body['collected_at'] = supplied.toUtc().toIso8601String();
    return body;
  }
}
