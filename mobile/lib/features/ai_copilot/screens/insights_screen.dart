import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../journal/providers/wellness_provider.dart';
import '../data/longitudinal_insight_service.dart';
import '../models/chat_turn.dart';
import '../providers/chat_provider.dart';
import '../widgets/chat_view.dart';
import '../widgets/local_patterns_section.dart';

/// The concierge.
///
/// Until F7 this screen offered five preset chips and answered them from
/// whatever the phone happened to have, which is why the old copy ended with
/// "Open-ended AI chat requires the FastAPI wellness service". It now asks the
/// server, which answers from the user's own records: the stored readiness and
/// biological-age snapshots, confirmed lab values, and findings a clinician
/// has signed.
///
/// The locally computed patterns stay, under the conversation and labelled as
/// what they are. They are the one thing on this screen that works with no
/// connection at all, and showing them beside server answers is only honest
/// because the label says which is which.
class InsightsScreen extends ConsumerWidget {
  const InsightsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(chatHistoryProvider);
    final wellness = ref.watch(wellnessProvider);

    // A conversation we could not read is not a conversation that does not
    // exist — but the only useful thing to offer is a new question, so the
    // error state is an empty conversation rather than a dead screen.
    final turns = history.maybeWhen(
      data: (turns) => turns,
      orElse: () => const <ChatTurn>[],
    );

    if (history.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return ChatView(
      history: turns,
      onAsk: (message) => ref.read(chatRepositoryProvider).ask(message),
      footer: wellness.maybeWhen(
        data: (data) => LocalPatternsSection(
          insights: const LongitudinalInsightService().build(data),
        ),
        orElse: () => null,
      ),
    );
  }
}
