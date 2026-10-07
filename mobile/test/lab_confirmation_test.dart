import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/labs/data/lab_confirmation.dart';
import 'package:telomy/features/labs/models/biomarker_result.dart';
import 'package:telomy/features/labs/models/lab_upload.dart';

/// The confirmation screen's rules, as pure logic.
///
/// The gateway refuses a confirmation that is incomplete, names someone else,
/// or has no collection date. The screen must refuse it first and say why, or
/// the user meets a 422 they cannot interpret. Keeping the rules here rather
/// than in widget state is what makes that testable.

LabUpload upload({
  String status = 'extracted',
  String? patientName = 'MRS SUNITA R PATNAIK',
  String collectedAtSource = 'extracted',
  DateTime? collectedAt,
}) {
  return LabUpload(
    id: 'u1',
    status: status,
    collectedAt: collectedAt ?? DateTime.utc(2026, 9, 28, 7, 30),
    collectedAtSource: collectedAtSource,
    reportedAt: DateTime.utc(2026, 9, 29, 11),
    patientName: patientName,
    labName: 'Dr Lal PathLabs',
    isHistory: false,
    pageCount: 1,
    error: null,
  );
}

BiomarkerResult result(
  String id, {
  String biomarkerId = 'hba1c',
  String operator = '=',
  String rawValue = '7.8',
  String grade = 'ungraded',
  Map<String, dynamic>? bbox,
}) {
  return BiomarkerResult(
    id: id,
    biomarkerId: biomarkerId,
    context: 'standard',
    resultType: 'quantitative',
    operator: operator,
    rawValue: rawValue,
    rawUnit: '%',
    valueCanonical: double.tryParse(rawValue),
    unitCanonical: '%',
    grade: grade,
    page: 0,
    confidence: 1,
    bbox: bbox ??
        const {
          'x0': 250.0, 'x1': 270.0, 'top': 100.0, 'bottom': 110.0,
          'page_width': 500.0, 'page_height': 1000.0,
        },
  );
}

ConfirmationDraft draftOf({
  LabUpload? on,
  List<BiomarkerResult>? results,
}) {
  return ConfirmationDraft(
    upload: on ?? upload(),
    results: results ?? [result('r1'), result('r2', biomarkerId: 'ferritin')],
  );
}

void main() {
  group('deciding every result', () {
    test('a fresh draft cannot be submitted', () {
      final draft = draftOf();

      expect(draft.canSubmit, isFalse);
      expect(draft.undecided, hasLength(2));
    });

    test('deciding every result and confirming identity unblocks it', () {
      final draft = draftOf()
        ..confirm('r1')
        ..confirm('r2')
        ..patientIsMe = true;

      expect(draft.canSubmit, isTrue);
      expect(draft.blockers, isEmpty);
    });

    test('a partially decided draft names what is missing', () {
      final draft = draftOf()
        ..confirm('r1')
        ..patientIsMe = true;

      expect(draft.canSubmit, isFalse);
      expect(draft.blockers.join(' '), contains('1 value'));
    });

    test('rejecting counts as deciding', () {
      final draft = draftOf()
        ..confirm('r1')
        ..reject('r2')
        ..patientIsMe = true;

      expect(draft.canSubmit, isTrue);
    });

    test('a correction needs a value', () {
      final draft = draftOf()
        ..correct('r1', value: null, unit: '%')
        ..confirm('r2')
        ..patientIsMe = true;

      expect(draft.canSubmit, isFalse);
      expect(draft.blockers.join(' ').toLowerCase(), contains('value'));
    });

    test('a correction with a value is complete', () {
      final draft = draftOf()
        ..correct('r1', value: 6.5, unit: '%')
        ..confirm('r2')
        ..patientIsMe = true;

      expect(draft.canSubmit, isTrue);
    });
  });

  group('the patient-name check', () {
    test('a named report must be confirmed as the user before submitting', () {
      final draft = draftOf()
        ..confirm('r1')
        ..confirm('r2');

      expect(draft.needsPatientConfirmation, isTrue);
      expect(draft.canSubmit, isFalse);
    });

    test('saying it is someone else blocks rather than submits', () {
      final draft = draftOf()
        ..confirm('r1')
        ..confirm('r2')
        ..patientIsMe = false;

      expect(draft.canSubmit, isFalse);
      expect(draft.blockers.join(' '), contains('SUNITA'));
    });

    test('a report with no name on it does not ask', () {
      final draft = draftOf(on: upload(patientName: null))
        ..confirm('r1')
        ..confirm('r2');

      expect(draft.needsPatientConfirmation, isFalse);
      expect(draft.canSubmit, isTrue);
    });
  });

  group('the collection date', () {
    test('an uncertain date must be supplied', () {
      final draft = draftOf(on: upload(collectedAtSource: 'unknown'))
        ..confirm('r1')
        ..confirm('r2')
        ..patientIsMe = true;

      expect(draft.needsCollectionDate, isTrue);
      expect(draft.canSubmit, isFalse);
      expect(draft.blockers.join(' ').toLowerCase(), contains('collect'));
    });

    test('supplying it unblocks', () {
      final draft = draftOf(on: upload(collectedAtSource: 'unknown'))
        ..confirm('r1')
        ..confirm('r2')
        ..patientIsMe = true
        ..collectedAt = DateTime.utc(2026, 9, 28);

      expect(draft.canSubmit, isTrue);
    });

    test('a confidently extracted date is not asked for again', () {
      final draft = draftOf()
        ..confirm('r1')
        ..confirm('r2')
        ..patientIsMe = true;

      expect(draft.needsCollectionDate, isFalse);
    });

    test('a future collection date is refused', () {
      final draft = draftOf(on: upload(collectedAtSource: 'unknown'))
        ..confirm('r1')
        ..confirm('r2')
        ..patientIsMe = true
        ..collectedAt = DateTime.now().add(const Duration(days: 2));

      expect(draft.canSubmit, isFalse);
      expect(draft.blockers.join(' ').toLowerCase(), contains('future'));
    });
  });

  group('the request it builds', () {
    test('it matches what the endpoint expects', () {
      final draft = draftOf()
        ..confirm('r1')
        ..correct('r2', value: 120, unit: 'ng/mL')
        ..patientIsMe = true;

      final body = draft.toRequest();

      expect(body['patient_is_me'], isTrue);
      final decisions = body['decisions'] as List;
      expect(decisions, hasLength(2));
      final corrected =
          decisions.firstWhere((d) => (d as Map)['result_id'] == 'r2') as Map;
      expect(corrected['action'], 'correct');
      expect(corrected['value'], 120);
      expect(corrected['unit'], 'ng/mL');
    });

    test('a supplied collection date is sent in UTC ISO form', () {
      final draft = draftOf(on: upload(collectedAtSource: 'unknown'))
        ..confirm('r1')
        ..confirm('r2')
        ..patientIsMe = true
        ..collectedAt = DateTime.utc(2026, 9, 28, 7, 30);

      expect(draft.toRequest()['collected_at'], startsWith('2026-09-28'));
    });

    test('no date is sent when the server already has a confident one', () {
      final draft = draftOf()
        ..confirm('r1')
        ..confirm('r2')
        ..patientIsMe = true;

      expect(draft.toRequest().containsKey('collected_at'), isFalse);
    });

    test('a confirm decision carries no value or unit', () {
      final draft = draftOf()
        ..confirm('r1')
        ..confirm('r2')
        ..patientIsMe = true;

      final first = (draft.toRequest()['decisions'] as List).first as Map;
      expect(first.containsKey('value'), isFalse);
    });
  });

  group('what the screen may claim', () {
    test('an ungraded result is not presented as a verdict', () {
      expect(result('r1').hasNoVerdict, isTrue);
    });

    test('a censored value keeps its operator when displayed', () {
      expect(result('r1', operator: '<', rawValue: '3.0').displayValue, '<3.0');
    });

    test('an uncensored value is displayed exactly as printed', () {
      expect(result('r1', rawValue: '7.8').displayValue, '7.8');
    });

    test('a report already confirmed cannot be confirmed again', () {
      final draft = draftOf(on: upload(status: 'confirmed'))
        ..confirm('r1')
        ..confirm('r2')
        ..patientIsMe = true;

      expect(draft.canSubmit, isFalse);
      expect(draft.blockers.join(' ').toLowerCase(), contains('already'));
    });
  });
}
