import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/providers/auth_provider.dart';
import '../data/centre_repository.dart';
import '../models/centre_roster.dart';

final centreRepositoryProvider = Provider(
  (ref) => CentreRepository(http: ref.watch(apiClientProvider).dio),
);
final myCentresProvider = FutureProvider.autoDispose<List<CentreRef>>(
  (ref) => ref.read(centreRepositoryProvider).mine(),
);
final selectedCentreProvider = NotifierProvider<SelectedCentre, String?>(
  SelectedCentre.new,
);

class SelectedCentre extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String id) => state = id;
}

final centreDoctorsProvider = FutureProvider.autoDispose
    .family<List<CentrePerson>, String>(
      (ref, id) => ref.read(centreRepositoryProvider).doctors(id),
    );
final centrePatientsProvider = FutureProvider.autoDispose
    .family<List<CentrePerson>, String>(
      (ref, id) => ref.read(centreRepositoryProvider).patients(id),
    );
