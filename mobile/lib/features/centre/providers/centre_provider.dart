import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/centre_repository.dart';
import '../models/centre_operations.dart';
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

  void select(String membershipId) {
    final previous = state;
    if (previous == membershipId) return;
    state = membershipId;
    if (previous != null) invalidateCentreMembership(ref, previous);
  }
}

final centreDashboardProvider = FutureProvider.autoDispose
    .family<CentreDashboard, String>(
      (ref, membershipId) =>
          ref.read(centreRepositoryProvider).dashboard(membershipId),
    );

final centreDoctorsProvider = FutureProvider.autoDispose
    .family<List<CentrePerson>, String>(
      (ref, membershipId) =>
          ref.read(centreRepositoryProvider).doctors(membershipId),
    );

final centreMembersProvider = FutureProvider.autoDispose
    .family<List<CentreMember>, String>(
      (ref, membershipId) =>
          ref.read(centreRepositoryProvider).members(membershipId),
    );

final centrePatientsProvider = FutureProvider.autoDispose
    .family<List<CentrePerson>, String>(
      (ref, membershipId) =>
          ref.read(centreRepositoryProvider).patients(membershipId),
    );

final centreRoomsProvider = FutureProvider.autoDispose
    .family<CentreRooms, String>(
      (ref, membershipId) =>
          ref.read(centreRepositoryProvider).rooms(membershipId),
    );

final centreServicesProvider = FutureProvider.autoDispose
    .family<CentreServices, String>(
      (ref, membershipId) =>
          ref.read(centreRepositoryProvider).services(membershipId),
    );

final centreBookingsProvider = FutureProvider.autoDispose
    .family<List<CentreBooking>, String>(
      (ref, membershipId) =>
          ref.read(centreRepositoryProvider).bookings(membershipId),
    );

final activeCentreDashboardProvider =
    FutureProvider.autoDispose<CentreDashboard>((ref) async {
      final membershipId = ref.watch(selectedCentreProvider);
      if (membershipId == null) {
        throw const CentreUnavailable('Select a centre to continue.');
      }
      return ref.watch(centreDashboardProvider(membershipId).future);
    });

void invalidateCentreMembership(Ref ref, String membershipId) {
  ref.invalidate(centreDashboardProvider(membershipId));
  ref.invalidate(centreDoctorsProvider(membershipId));
  ref.invalidate(centreMembersProvider(membershipId));
  ref.invalidate(centrePatientsProvider(membershipId));
  ref.invalidate(centreRoomsProvider(membershipId));
  ref.invalidate(centreServicesProvider(membershipId));
  ref.invalidate(centreBookingsProvider(membershipId));
}
