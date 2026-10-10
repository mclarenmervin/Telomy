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
  String resultType = 'quantitative',
  String rawUnit = '%',
}) {
  return BiomarkerResult(
    id: id,
    biomarkerId: biomarkerId,
    context: 'standard',
    resultType: resultType,
    operator: operator,
    rawValue: rawValue,
    rawUnit: rawUnit,
    valueCanonical: double.tryParse(rawValue),
    unitCanonical: rawUnit,
    grade: grade,
    page: 0,
    confidence: 1,
    collectedAt: DateTime.utc(2026, 9, 28),
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
  group('an upload still being read', () {
    test('a fresh upload is in flight', () {
      expect(upload(status: 'uploaded').isInFlight, isTrue);
      expect(upload(status: 'extracting').isInFlight, isTrue);
    });

    test('a finished upload is not', () {
      // Found on a real device: the list cached its value, so the tile said
      // "Reading the report..." after the server had finished and the user
      // could never reach the confirmation screen.
      expect(upload(status: 'extracted').isInFlight, isFalse);
      expect(upload(status: 'confirmed').isInFlight, isFalse);
      expect(upload(status: 'failed').isInFlight, isFalse);
      expect(upload(status: 'needs_password').isInFlight, isFalse);
    });
  });

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

  group('how a result reads in a list', () {
    test('an ordinary marker reads as its printed name', () {
      // Was asserting 'hba1c', which is the identifier and not a label. Found
      // on a device: the confirmed-results list read "hba1c", "wbc" and
      // "alkaline phosphatase" down the screen while every test passed —
      // the same bug as F4's "Rdw" and "Hs crp", one layer along.
      expect(result('r1', biomarkerId: 'hba1c').displayLabel, 'HbA1c');
    });

    test('an acronym keeps the form a lab report prints', () {
      expect(result('r1', biomarkerId: 'wbc').displayLabel, 'WBC');
      expect(result('r1', biomarkerId: 'hs_crp').displayLabel, 'hs-CRP');
    });

    test('a marker the app has not heard of still reads as words', () {
      // A marker added to the catalog after this build shipped. It must not
      // fall back to showing a database identifier.
      expect(
        result('r1', biomarkerId: 'some_new_marker').displayLabel,
        'Some new marker',
      );
    });

    test('a context that changes the meaning is shown', () {
      // Fasting and post-prandial glucose are one marker and two results. A
      // list showing both as "glucose fasting" is not a list anyone can use.
      final r = BiomarkerResult(
        id: 'r1', biomarkerId: 'glucose_fasting', context: 'post_prandial',
        resultType: 'quantitative', operator: '=', rawValue: '198',
        rawUnit: 'mg/dL', valueCanonical: 198, unitCanonical: 'mg/dL',
        grade: 'ungraded', page: 0, confidence: 1, bbox: null,
        collectedAt: null,
      );

      expect(r.displayLabel, 'Fasting glucose (post prandial)');
    });

    test('a percentage takes no space before the sign', () {
      // Was asserting '7.8 %'. No lab report prints it that way, and a user
      // checking the screen against their own PDF should read the same string
      // on both.
      expect(result('r1', rawValue: '7.8').displayValueWithUnit, '7.8%');
    });

    test('any other unit keeps its space', () {
      expect(
        result('r1', biomarkerId: 'haemoglobin', rawValue: '12.4',
               rawUnit: 'g/dL').displayValueWithUnit,
        '12.4 g/dL',
      );
    });

    test('a censored value keeps its operator in the list too', () {
      expect(
        result('r1', operator: '<', rawValue: '3.0').displayValueWithUnit,
        '<3.0%',
      );
    });
  });

  group('text results', () {
    test('a qualitative result shows the words the lab printed', () {
      final r = result('r1', resultType: 'qualitative', rawValue: 'Not detected');

      expect(r.isQualitative, isTrue);
      expect(r.displayValue, 'Not detected');
    });

    test('a qualitative result is never treated as censored', () {
      // The operator belongs to numbers. Text has no magnitude to be bounded.
      expect(result('r1', resultType: 'qualitative').isCensored, isFalse);
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
