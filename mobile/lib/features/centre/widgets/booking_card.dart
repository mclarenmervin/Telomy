import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/surfaces.dart';
import '../models/centre_operations.dart';
import '../utils/centre_time.dart';

typedef BookingCommand =
    Future<void> Function(String command, int version, String? reason);

class BookingCard extends StatelessWidget {
  const BookingCard({
    super.key,
    required this.booking,
    required this.onCommand,
    this.now,
    this.timezoneName = 'UTC',
  });

  final CentreBooking booking;
  final BookingCommand onCommand;
  final DateTime? now;
  final String timezoneName;

  @override
  Widget build(BuildContext context) {
    final localStart = centreLocalTime(booking.scheduledStart, timezoneName);
    final localEnd = centreLocalTime(booking.scheduledEnd, timezoneName);
    final current = now ?? DateTime.now().toUtc();
    final noShowAt = booking.scheduledStart.toUtc().add(
      const Duration(minutes: 15),
    );
    final noShowReady = !current.toUtc().isBefore(noShowAt);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  booking.serviceNameSnapshot,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              _Status(status: booking.status),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${_date(localStart)} · ${_time(localStart)}–${_time(localEnd)}',
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            'Patient ${booking.patientDisplayName} · Room ${booking.roomName}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (booking.status == 'booked' && !noShowReady) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'No-show is available after the 15-minute grace period.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          if (booking.isTerminal)
            Text(switch (booking.status) {
              'completed' => 'Booking complete',
              'no_show' => 'Marked no-show',
              _ => 'Booking cancelled',
            }, style: Theme.of(context).textTheme.labelLarge)
          else
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                if (booking.status == 'booked')
                  FilledButton(
                    onPressed: () =>
                        onCommand('check_in', booking.version, null),
                    child: const Text('Check in'),
                  ),
                if (booking.status == 'checked_in')
                  FilledButton(
                    onPressed: () =>
                        onCommand('complete', booking.version, null),
                    child: const Text('Complete'),
                  ),
                if (booking.status == 'booked')
                  TextButton(
                    onPressed: noShowReady
                        ? () => onCommand('mark_no_show', booking.version, null)
                        : null,
                    child: const Text('Mark no-show'),
                  ),
                TextButton(
                  onPressed: () => _cancel(context),
                  child: const Text('Cancel'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _cancel(BuildContext context) async {
    String? reason;
    if (booking.status == 'checked_in') {
      var draft = '';
      reason = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Cancel checked-in booking'),
          content: TextField(
            autofocus: true,
            onChanged: (value) => draft = value,
            decoration: const InputDecoration(labelText: 'Cancellation reason'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Keep booking'),
            ),
            FilledButton(
              onPressed: () {
                final value = draft.trim();
                if (value.isNotEmpty) Navigator.pop(context, value);
              },
              child: const Text('Cancel booking'),
            ),
          ],
        ),
      );
      if (reason == null) return;
    }
    await onCommand('cancel', booking.version, reason);
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.xs,
      vertical: AppSpacing.xxs,
    ),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppRadii.pill),
    ),
    child: Text(status, style: Theme.of(context).textTheme.labelSmall),
  );
}

String _date(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
String _time(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
