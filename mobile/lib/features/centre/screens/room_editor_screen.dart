import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';

class RoomDraft {
  const RoomDraft({
    required this.name,
    required this.weekday,
    required this.opensAt,
    required this.closesAt,
  });
  final String name;
  final int weekday;
  final String opensAt;
  final String closesAt;
}

class RoomEditorScreen extends StatefulWidget {
  const RoomEditorScreen({super.key, required this.onCreate});
  final Future<void> Function(RoomDraft draft) onCreate;

  @override
  State<RoomEditorScreen> createState() => _RoomEditorScreenState();
}

class _RoomEditorScreenState extends State<RoomEditorScreen> {
  final name = TextEditingController();
  final opens = TextEditingController(text: '09:00');
  final closes = TextEditingController(text: '17:00');
  int weekday = 1;
  bool saving = false;

  bool get timeFormat =>
      RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(opens.text) &&
      RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(closes.text);
  bool get ordered => timeFormat && closes.text.compareTo(opens.text) > 0;
  bool get valid => name.text.trim().isNotEmpty && ordered && !saving;

  @override
  void dispose() {
    name.dispose();
    opens.dispose();
    closes.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!valid) return;
    setState(() => saving = true);
    try {
      await widget.onCreate(
        RoomDraft(
          name: name.text.trim(),
          weekday: weekday,
          opensAt: opens.text,
          closesAt: closes.text,
        ),
      );
      if (mounted) Navigator.maybePop(context);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Create room')),
    body: ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        _field(name, 'Room name'),
        DropdownButtonFormField<int>(
          initialValue: weekday,
          decoration: const InputDecoration(labelText: 'Weekday'),
          items: const [
            DropdownMenuItem(value: 0, child: Text('Sunday')),
            DropdownMenuItem(value: 1, child: Text('Monday')),
            DropdownMenuItem(value: 2, child: Text('Tuesday')),
            DropdownMenuItem(value: 3, child: Text('Wednesday')),
            DropdownMenuItem(value: 4, child: Text('Thursday')),
            DropdownMenuItem(value: 5, child: Text('Friday')),
            DropdownMenuItem(value: 6, child: Text('Saturday')),
          ],
          onChanged: (value) => setState(() => weekday = value ?? weekday),
        ),
        const SizedBox(height: AppSpacing.sm),
        _field(opens, 'Opens (HH:mm)'),
        _field(closes, 'Closes (HH:mm)'),
        if (timeFormat && !ordered)
          const Text('Closing time must be after opening time.'),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: valid ? save : null,
          child: Text(saving ? 'Creating…' : 'Create room'),
        ),
      ],
    ),
  );

  Widget _field(TextEditingController controller, String label) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: TextField(
      controller: controller,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(labelText: label),
    ),
  );
}
