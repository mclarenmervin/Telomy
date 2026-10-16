import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';

class TherapyCheckinQuestion {
  const TherapyCheckinQuestion({required this.code, required this.prompt});
  final String code, prompt;
}

class TherapyCheckinSheet extends StatefulWidget {
  const TherapyCheckinSheet({
    super.key,
    required this.questions,
    required this.onSubmit,
  });
  final List<TherapyCheckinQuestion> questions;
  final Future<void> Function(Map<String, String> answers) onSubmit;
  @override
  State<TherapyCheckinSheet> createState() => _TherapyCheckinSheetState();
}

class _TherapyCheckinSheetState extends State<TherapyCheckinSheet> {
  final answers = <String, String>{};
  @override
  Widget build(BuildContext context) {
    final questions = widget.questions.take(2).toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'How did it go?',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: AppSpacing.md),
          for (final question in questions)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: TextField(
                decoration: InputDecoration(labelText: question.prompt),
                onChanged: (value) =>
                    setState(() => answers[question.code] = value),
              ),
            ),
          FilledButton(
            onPressed: questions.isEmpty ||
                    (answers[questions.first.code]?.trim().isNotEmpty != true)
                ? null
                : () => widget.onSubmit(answers),
            child: const Text('Save check-in'),
          ),
        ],
      ),
    );
  }
}
