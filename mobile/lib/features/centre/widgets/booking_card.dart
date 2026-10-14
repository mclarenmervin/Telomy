import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/surfaces.dart';
import '../models/centre_operations.dart';

typedef BookingCommand = Future<void> Function(String command, int version);

class BookingCard extends StatelessWidget {
  const BookingCard({
    super.key,
    required this.booking,
    required this.onCommand,
    this.now,
  });

  final CentreBooking booking;
  final BookingCommand onCommand;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final localStart = booking.scheduledStart.toLocal();
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
            '${_date(localStart)} · ${_time(localStart)}–${_time(booking.scheduledEnd.toLocal())}',
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            'Patient ${booking.patientId} · Room ${booking.roomId}',
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
                    onPressed: () => onCommand('check_in', booking.version),
                    child: const Text('Check in'),
                  ),
                if (booking.status == 'checked_in')
                  FilledButton(
                    onPressed: () => onCommand('complete', booking.version),
                    child: const Text('Complete'),
                  ),
                if (booking.status == 'booked')
                  TextButton(
                    onPressed: noShowReady
                        ? () => onCommand('mark_no_show', booking.version)
                        : null,
                    child: const Text('Mark no-show'),
                  ),
                TextButton(
                  onPressed: () => onCommand('cancel', booking.version),
                  child: const Text('Cancel'),
                ),
              ],
            ),
        ],
      ),
    );
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
