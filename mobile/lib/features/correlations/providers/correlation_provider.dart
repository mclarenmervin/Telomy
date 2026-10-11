import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/correlation_repository.dart';
import '../models/correlation.dart';

final correlationRepositoryProvider = Provider(
  (ref) => CorrelationRepository(http: ref.watch(apiClientProvider).dio),
);

/// The window the screen is showing. Thirty days is the shortest the engine
/// accepts; below that it could only ever answer "nothing found".
class CorrelationWindow extends Notifier<int> {
  @override
  int build() => 90;
  void setDays(int value) => state = value;
}

final correlationWindowProvider = NotifierProvider<CorrelationWindow, int>(
  CorrelationWindow.new,
);

final correlationReportProvider = FutureProvider<CorrelationReport>((ref) async {
  final days = ref.watch(correlationWindowProvider);
  return ref.read(correlationRepositoryProvider).fetch(days: days);
});
