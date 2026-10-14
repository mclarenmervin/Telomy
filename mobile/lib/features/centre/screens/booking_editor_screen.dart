import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../models/centre_operations.dart';
import '../models/centre_roster.dart';
import '../utils/centre_time.dart';

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
  const BookingEditorScreen({
    super.key,
    required this.onCreate,
    this.timezoneName = 'UTC',
    this.patients = const [],
    this.services = const [],
    this.rooms = const [],
    this.compatibility = const [],
  });
  final Future<void> Function(BookingDraft draft) onCreate;
  final String timezoneName;
  final List<CentrePerson> patients;
  final List<CentreService> services;
  final List<CentreRoom> rooms;
  final List<RoomServiceLink> compatibility;

  @override
  State<BookingEditorScreen> createState() => _BookingEditorScreenState();
}

class _BookingEditorScreenState extends State<BookingEditorScreen> {
  String? patientId;
  String? serviceId;
  String? roomId;
  DateTime? scheduledStart;
  bool saving = false;

  bool get valid =>
      patientId != null &&
      serviceId != null &&
      roomId != null &&
      scheduledStart?.isAfter(DateTime.now()) == true &&
      !saving;

  @override
  void initState() {
    super.initState();
    patientId = widget.patients
        .where((item) => item.status == 'active')
        .firstOrNull
        ?.id;
    serviceId = widget.services
        .where((item) => item.status == 'active')
        .firstOrNull
        ?.id;
    roomId = compatibleRooms.firstOrNull?.id;
  }

  List<CentreRoom> get compatibleRooms {
    if (serviceId == null) return const [];
    final ids = widget.compatibility
        .where((link) => link.serviceId == serviceId && link.unlinkedAt == null)
        .map((link) => link.roomId)
        .toSet();
    return widget.rooms
        .where((room) => room.status == 'active' && ids.contains(room.id))
        .toList(growable: false);
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
      scheduledStart = centreUtcTime(
        date,
        time.hour,
        time.minute,
        widget.timezoneName,
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
          patientId: patientId!,
          serviceId: serviceId!,
          roomId: roomId!,
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
        _selector(
          label: 'Patient',
          value: patientId,
          items: [
            for (final patient in widget.patients.where(
              (item) => item.status == 'active',
            ))
              DropdownMenuItem(value: patient.id, child: Text(patient.name)),
          ],
          onChanged: (value) => setState(() => patientId = value),
        ),
        _selector(
          label: 'Service',
          value: serviceId,
          items: [
            for (final service in widget.services.where(
              (item) => item.status == 'active',
            ))
              DropdownMenuItem(value: service.id, child: Text(service.name)),
          ],
          onChanged: (value) => setState(() {
            serviceId = value;
            roomId = compatibleRooms.firstOrNull?.id;
          }),
        ),
        _selector(
          label: 'Compatible room',
          value: roomId,
          items: [
            for (final room in compatibleRooms)
              DropdownMenuItem(value: room.id, child: Text(room.name)),
          ],
          onChanged: (value) => setState(() => roomId = value),
        ),
        if (widget.patients.isEmpty ||
            widget.services.isEmpty ||
            compatibleRooms.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text(
              'An active patient, service, and compatible room are required.',
            ),
          ),
        OutlinedButton.icon(
          onPressed: chooseTime,
          icon: const Icon(Icons.schedule_outlined),
          label: Text(
            scheduledStart == null
                ? 'Choose time'
                : centreLocalTime(
                    scheduledStart!,
                    widget.timezoneName,
                  ).toString().substring(0, 16),
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

  Widget _selector({
    required String label,
    required String? value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: DropdownButtonFormField<String>(
      initialValue: value,
      items: items,
      onChanged: items.isEmpty ? null : onChanged,
      decoration: InputDecoration(labelText: label),
    ),
  );
}
