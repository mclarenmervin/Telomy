import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/chat_repository.dart';
import '../models/chat_turn.dart';

/// Asking goes over REST, so the repository needs the authenticated Dio
/// instance; reading the conversation back rides the Supabase client the app
/// already uses, exactly as scores and lab uploads do.
final chatRepositoryProvider = Provider(
  (ref) => ChatRepository(http: ref.watch(apiClientProvider).dio),
);

/// The conversation so far, oldest first.
///
/// Not autoDispose: coming back to the tab should show the conversation that
/// is already there rather than refetching it, and new turns are appended by
/// the view as they are answered.
final chatHistoryProvider = FutureProvider<List<ChatTurn>>((ref) async {
  final user = ref.watch(authProvider).asData?.value;
  if (user == null) return const [];
  return ref.read(chatRepositoryProvider).history(userId: user.id);
});
