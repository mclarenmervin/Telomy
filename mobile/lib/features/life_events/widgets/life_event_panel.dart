import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/life_event_provider.dart';
import 'life_event_card.dart';

/// The event card wired to its controller. Kept thin: everything that decides
/// what the user sees lives in [LifeEventCardBody], which is tested directly.
class LifeEventPanel extends ConsumerWidget {
  const LifeEventPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(lifeEventProvider);
    final controller = ref.read(lifeEventProvider.notifier);
    return LifeEventCardBody(
      state: state,
      onStart: controller.start,
      onStop: controller.stop,
    );
  }
}
