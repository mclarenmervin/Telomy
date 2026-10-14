import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';

class BookingDraft {
  const BookingDraft({
    required this.patientId,
    required this.serviceId,
    required this.roomId,
    required this.scheduledStart,
  });
  final String patientId;
  final String serviceId;
  final String roomId;
  final DateTime scheduledStart;
}

class BookingEditorScreen extends StatefulWidget {
  const BookingEditorScreen({super.key, required this.onCreate});
  final Future<void> Function(BookingDraft draft) onCreate;

  @override
  State<BookingEditorScreen> createState() => _BookingEditorScreenState();
}

class _BookingEditorScreenState extends State<BookingEditorScreen> {
  final patient = TextEditingController();
  final service = TextEditingController();
  final room = TextEditingController();
  DateTime? scheduledStart;
  bool saving = false;

  bool get valid =>
      patient.text.trim().isNotEmpty &&
      service.text.trim().isNotEmpty &&
      room.text.trim().isNotEmpty &&
      scheduledStart?.isAfter(DateTime.now()) == true &&
      !saving;

  @override
  void dispose() {
    patient.dispose();
    service.dispose();
    room.dispose();
    super.dispose();
  }

  Future<void> chooseTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
    );
    if (time == null) return;
    setState(() {
      scheduledStart = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> save() async {
    if (!valid) return;
    setState(() => saving = true);
    var created = false;
    try {
      await widget.onCreate(
        BookingDraft(
          patientId: patient.text.trim(),
          serviceId: service.text.trim(),
          roomId: room.text.trim(),
          scheduledStart: scheduledStart!,
        ),
      );
      created = true;
    } catch (_) {
      // The parent owns the user-facing, non-sensitive error message.
    } finally {
      if (mounted) setState(() => saving = false);
    }
    if (created && mounted) Navigator.maybePop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Create booking')),
    body: ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        _field(patient, 'Patient ID'),
        _field(service, 'Service ID'),
        _field(room, 'Room ID'),
        OutlinedButton.icon(
          onPressed: chooseTime,
          icon: const Icon(Icons.schedule_outlined),
          label: Text(
            scheduledStart == null
                ? 'Choose time'
                : scheduledStart!.toLocal().toString().substring(0, 16),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          scheduledStart == null
              ? 'Choose a future appointment time.'
              : scheduledStart!.isAfter(DateTime.now())
              ? 'Future appointment selected.'
              : 'Appointment must be in the future.',
        ),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: valid ? save : null,
          child: Text(saving ? 'Creating…' : 'Create booking'),
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
