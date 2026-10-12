import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/providers/auth_provider.dart';
import '../data/doctor_repository.dart';
import '../models/doctor_models.dart';

final doctorRepositoryProvider = Provider(
  (ref) => DoctorRepository(http: ref.watch(apiClientProvider).dio),
);
final doctorCentresProvider = FutureProvider.autoDispose(
  (ref) => ref.read(doctorRepositoryProvider).centres(),
);
final selectedDoctorCentreProvider =
    NotifierProvider<SelectedDoctorCentre, String?>(SelectedDoctorCentre.new);

class SelectedDoctorCentre extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String id) => state = id;
}

final doctorTodayProvider = FutureProvider.autoDispose
    .family<DoctorToday, String>(
      (ref, c) => ref.read(doctorRepositoryProvider).today(c),
    );
final doctorPatientsProvider = FutureProvider.autoDispose
    .family<List<DoctorPatient>, String>(
      (ref, c) => ref.read(doctorRepositoryProvider).patients(c),
    );
final doctorPatientProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, DoctorPatientKey>(
      (ref, k) =>
          ref.read(doctorRepositoryProvider).patient(k.centreId, k.patientId),
    );
final doctorWorkQueueProvider = FutureProvider.autoDispose
    .family<DoctorWorkQueue, String>(
      (ref, c) => ref.read(doctorRepositoryProvider).workQueue(c),
    );
final doctorProfileProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (ref) => ref.read(doctorRepositoryProvider).profile(),
);
void invalidateDoctorCentre(Ref ref, String centreId) {
  ref.invalidate(doctorTodayProvider(centreId));
  ref.invalidate(doctorPatientsProvider(centreId));
  ref.invalidate(doctorWorkQueueProvider(centreId));
}
