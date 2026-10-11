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

/// Worked out again each time the screen is opened.
///
/// `autoDispose`, unlike the chat history, and the difference is what each
/// one is. A conversation is a record: coming back to it should show the
/// conversation that is already there. A set of patterns is a calculation
/// over readings that arrive all day, and its most common answer early on is
/// "there is not enough recorded yet" — which a cached provider will keep
/// saying for the life of the app after the data has arrived. Found on the
/// emulator doing exactly that: sixty days of readings landed and reopening
/// the screen still said there was nothing to test, because one request had
/// been made and never repeated.
final correlationReportProvider =
    FutureProvider.autoDispose<CorrelationReport>((ref) async {
  final days = ref.watch(correlationWindowProvider);
  return ref.read(correlationRepositoryProvider).fetch(days: days);
});
