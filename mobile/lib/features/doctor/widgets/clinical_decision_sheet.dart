import 'package:flutter/material.dart';

class ClinicalDecisionSheet extends StatefulWidget {
  const ClinicalDecisionSheet({
    super.key,
    required this.onSign,
    required this.onReject,
  });
  final Future<void> Function(String note) onSign, onReject;
  @override
  State<ClinicalDecisionSheet> createState() => _ClinicalDecisionSheetState();
}

class _ClinicalDecisionSheetState extends State<ClinicalDecisionSheet> {
  final note = TextEditingController();
  bool busy = false;
  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: 16,
      right: 16,
      top: 16,
      bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
    ),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Clinical decision'),
          TextField(
            controller: note,
            maxLines: 5,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Required clinical note',
            ),
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy || note.text.trim().isEmpty
                      ? null
                      : () => run(widget.onReject),
                  child: const Text('Reject'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: busy || note.text.trim().isEmpty
                      ? null
                      : () => run(widget.onSign),
                  child: const Text('Sign'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  Future<void> run(Future<void> Function(String) action) async {
    setState(() => busy = true);
    try {
      await action(note.text.trim());
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
