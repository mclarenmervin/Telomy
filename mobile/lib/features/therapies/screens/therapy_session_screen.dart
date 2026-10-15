import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/vocabulary.dart';
import '../models/therapy_session.dart';

class TherapySessionScreen extends StatelessWidget {
  const TherapySessionScreen({super.key, required this.session, this.onStart, this.onFinish});
  final TherapySession session;
  final VoidCallback? onStart, onFinish;

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Therapy session')),
    body: AppScreen(children: [
      T(_statusLabel(session.status), v: TextVariant.h2),
      const SizedBox(height: AppSpacing.lg),
      AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        T('Prescribed: ${therapyDoseText(session.prescribedDose)}'),
        const SizedBox(height: AppSpacing.xs),
        T('Delivered: ${therapyDoseText(session.deliveredDose)}'),
      ])),
      if (session.status == 'scheduled') FilledButton(onPressed: onStart, child: const Text('Start session')),
      if (session.status == 'started') FilledButton(onPressed: onFinish, child: const Text('Finish session')),
    ]),
  );
}

String _statusLabel(String status) => switch (status) {
  'scheduled' => 'Scheduled', 'started' => 'In progress', 'completed' => 'Completed',
  'refused' => 'Unable to start safely', 'cancelled' => 'Cancelled', _ => status,
};
