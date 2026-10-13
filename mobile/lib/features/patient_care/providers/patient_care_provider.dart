import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/patient_care_repository.dart';
import '../models/patient_care.dart';

final patientCareRepositoryProvider = Provider(
  (ref) => PatientCareRepository(http: ref.watch(apiClientProvider).dio),
);

final patientCareProvider = FutureProvider.autoDispose<PatientCare>(
  (ref) => ref.read(patientCareRepositoryProvider).read(),
);

final patientCareActionsProvider = Provider(PatientCareActions.new);

class PatientCareActions {
  PatientCareActions(this.ref);
  final Ref ref;

  Future<void> setConsent(String centreId, bool granted) async {
    await ref.read(patientCareRepositoryProvider).setConsent(centreId, granted);
    ref.invalidate(patientCareProvider);
  }
}
