import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../data/centre_repository.dart';
import '../models/centre_operations.dart';
import '../providers/centre_provider.dart';
import '../widgets/booking_card.dart';
import 'booking_editor_screen.dart';
import 'centre_dashboard_screen.dart';

typedef BookingTransitionAction =
    Future<CentreBooking?> Function(String command, int version);
typedef ScopedBookingTransitionAction =
    Future<CentreBooking?> Function(
      String bookingId,
      String command,
      int version,
    );
typedef BookingCreateAction =
    Future<CentreBooking?> Function(BookingDraft draft);

class BookingsScreen extends StatefulWidget {
  const BookingsScreen({
    super.key,
    this.initial,
    this.onRefresh,
    this.onTransition,
    this.onBookingTransition,
    this.onCreate,
    this.initialDate,
  });

  final List<CentreBooking>? initial;
  final Future<void> Function()? onRefresh;
  final BookingTransitionAction? onTransition;
  final ScopedBookingTransitionAction? onBookingTransition;
  final BookingCreateAction? onCreate;
  final DateTime? initialDate;

  @override
  State<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends State<BookingsScreen> {
  late List<CentreBooking> bookings = [...?widget.initial];
  late DateTime? selectedDate = widget.initialDate;
  String status = 'all';

  @override
  void didUpdateWidget(covariant BookingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initial != oldWidget.initial && widget.initial != null) {
      bookings = [...widget.initial!];
    }
  }

  Future<void> transition(
    CentreBooking booking,
    String command,
    int version,
  ) async {
    try {
      final updated = widget.onBookingTransition != null
          ? await widget.onBookingTransition!(booking.id, command, version)
          : await widget.onTransition?.call(command, version);
      if (updated != null && mounted) {
        setState(() {
          bookings = [
            for (final item in bookings) item.id == updated.id ? updated : item,
          ];
        });
      }
    } on CentreConflict catch (error) {
      await widget.onRefresh?.call();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } on CentreUnavailable catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> create(BookingDraft draft) async {
    try {
      final created = await widget.onCreate?.call(draft);
      if (created != null && mounted) {
        setState(() => bookings = [created, ...bookings]);
      }
    } on CentreUnavailable catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.initial == null) return const _BookingsLoader();
    final visible = bookings.where((booking) {
      final statusMatches = status == 'all' || booking.status == status;
      final local = booking.scheduledStart.toLocal();
      final dateMatches =
          selectedDate == null ||
          (local.year == selectedDate!.year &&
              local.month == selectedDate!.month &&
              local.day == selectedDate!.day);
      return statusMatches && dateMatches;
    }).toList();
    return Material(
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Bookings',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              if (widget.onCreate != null)
                FilledButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => BookingEditorScreen(onCreate: create),
                    ),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add booking'),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final chosen = await showDatePicker(
                    context: context,
                    initialDate: selectedDate ?? DateTime.now(),
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 730)),
                  );
                  if (chosen != null) setState(() => selectedDate = chosen);
                },
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text(
                  selectedDate == null
                      ? 'Date'
                      : '${selectedDate!.day.toString().padLeft(2, '0')}/${selectedDate!.month.toString().padLeft(2, '0')}/${selectedDate!.year}',
                ),
              ),
              if (selectedDate != null)
                IconButton(
                  tooltip: 'Clear date filter',
                  onPressed: () => setState(() => selectedDate = null),
                  icon: const Icon(Icons.close),
                ),
              DropdownButton<String>(
                value: status,
                onChanged: (value) => setState(() => status = value ?? 'all'),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('All statuses')),
                  DropdownMenuItem(value: 'booked', child: Text('Booked')),
                  DropdownMenuItem(
                    value: 'checked_in',
                    child: Text('Checked in'),
                  ),
                  DropdownMenuItem(
                    value: 'completed',
                    child: Text('Completed'),
                  ),
                  DropdownMenuItem(value: 'no_show', child: Text('No-show')),
                  DropdownMenuItem(
                    value: 'cancelled',
                    child: Text('Cancelled'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
              child: Center(child: Text('No bookings match these filters.')),
            )
          else
            for (final booking in visible)
              BookingCard(
                booking: booking,
                onCommand: (command, version) =>
                    transition(booking, command, version),
              ),
        ],
      ),
    );
  }
}

class _BookingsLoader extends ConsumerWidget {
  const _BookingsLoader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final membershipId = activeCentre(ref);
    if (membershipId == null) {
      return const Center(child: Text('No active centre membership'));
    }
    return ref
        .watch(centreBookingsProvider(membershipId))
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) =>
              const Center(child: Text('Bookings are unavailable. Try again.')),
          data: (items) => BookingsScreen(
            initial: items,
            onRefresh: () async =>
                ref.invalidate(centreBookingsProvider(membershipId)),
            onBookingTransition: (bookingId, command, version) async {
              final updated = await ref
                  .read(centreRepositoryProvider)
                  .transitionBooking(
                    membershipId,
                    bookingId: bookingId,
                    command: command,
                    expectedVersion: version,
                  );
              ref.invalidate(centreBookingsProvider(membershipId));
              return updated;
            },
            onCreate: (draft) async {
              final created = await ref
                  .read(centreRepositoryProvider)
                  .createBooking(
                    membershipId,
                    patientId: draft.patientId,
                    serviceId: draft.serviceId,
                    roomId: draft.roomId,
                    scheduledStart: draft.scheduledStart,
                  );
              ref.invalidate(centreBookingsProvider(membershipId));
              return created;
            },
          ),
        );
  }
}
