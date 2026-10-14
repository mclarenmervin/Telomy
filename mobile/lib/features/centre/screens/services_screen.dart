import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/surfaces.dart';
import '../models/centre_operations.dart';
import '../providers/centre_provider.dart';
import 'centre_dashboard_screen.dart';
import 'room_editor_screen.dart';
import 'service_editor_screen.dart';

class ServicesScreen extends StatelessWidget {
  const ServicesScreen({
    super.key,
    this.initialServices,
    this.initialRooms,
    this.onRetire,
    this.onLink,
    this.onCreateService,
    this.onCreateRoom,
  });

  final CentreServices? initialServices;
  final CentreRooms? initialRooms;
  final Future<void> Function(String serviceId)? onRetire;
  final Future<void> Function(String serviceId, String roomId)? onLink;
  final Future<void> Function(ServiceDraft draft)? onCreateService;
  final Future<void> Function(RoomDraft draft)? onCreateRoom;

  @override
  Widget build(BuildContext context) =>
      initialServices == null || initialRooms == null
      ? const _ServicesLoader()
      : _ServicesView(
          services: initialServices!,
          rooms: initialRooms!,
          onRetire: onRetire,
          onLink: onLink,
          onCreateService: onCreateService,
          onCreateRoom: onCreateRoom,
        );
}

class _ServicesLoader extends ConsumerWidget {
  const _ServicesLoader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final membershipId = activeCentre(ref);
    if (membershipId == null) {
      return const Center(child: Text('No active centre membership'));
    }
    final services = ref.watch(centreServicesProvider(membershipId));
    final rooms = ref.watch(centreRoomsProvider(membershipId));
    if (services.isLoading || rooms.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (services.hasError || rooms.hasError) {
      return const Center(child: Text('Services are unavailable. Try again.'));
    }
    void refresh() {
      ref.invalidate(centreServicesProvider(membershipId));
      ref.invalidate(centreRoomsProvider(membershipId));
    }

    return _ServicesView(
      services: services.requireValue,
      rooms: rooms.requireValue,
      onRetire: (serviceId) async {
        await ref
            .read(centreRepositoryProvider)
            .setServiceStatus(
              membershipId,
              serviceId: serviceId,
              status: 'inactive',
            );
        refresh();
      },
      onLink: (serviceId, roomId) async {
        await ref
            .read(centreRepositoryProvider)
            .linkRoomService(
              membershipId,
              serviceId: serviceId,
              roomId: roomId,
            );
        refresh();
      },
      onCreateService: (draft) async {
        await ref
            .read(centreRepositoryProvider)
            .createService(
              membershipId,
              name: draft.name,
              description: draft.description,
              durationMinutes: draft.durationMinutes,
              indicativePriceMinor: draft.indicativePriceMinor,
              currencyCode: draft.currencyCode,
            );
        refresh();
      },
      onCreateRoom: (draft) async {
        final roomId = await ref
            .read(centreRepositoryProvider)
            .createRoom(membershipId, name: draft.name);
        await ref
            .read(centreRepositoryProvider)
            .addRoomHours(
              membershipId,
              roomId: roomId,
              weekday: draft.weekday,
              opensAt: draft.opensAt,
              closesAt: draft.closesAt,
              validFrom: DateTime.now().toIso8601String().substring(0, 10),
            );
        refresh();
      },
    );
  }
}

class _ServicesView extends StatelessWidget {
  const _ServicesView({
    required this.services,
    required this.rooms,
    this.onRetire,
    this.onLink,
    this.onCreateService,
    this.onCreateRoom,
  });
  final CentreServices services;
  final CentreRooms rooms;
  final Future<void> Function(String serviceId)? onRetire;
  final Future<void> Function(String serviceId, String roomId)? onLink;
  final Future<void> Function(ServiceDraft draft)? onCreateService;
  final Future<void> Function(RoomDraft draft)? onCreateRoom;

  @override
  Widget build(BuildContext context) => Material(
    child: ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Text('Services', style: Theme.of(context).textTheme.headlineMedium),
        const Text(
          'Operational catalogue, compatible rooms, and weekly availability.',
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          children: [
            if (onCreateService != null)
              FilledButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        ServiceEditorScreen(onCreate: onCreateService!),
                  ),
                ),
                icon: const Icon(Icons.add),
                label: const Text('Add service'),
              ),
            if (onCreateRoom != null)
              OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => RoomEditorScreen(onCreate: onCreateRoom!),
                  ),
                ),
                icon: const Icon(Icons.meeting_room_outlined),
                label: const Text('Add room'),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        for (final service in services.items)
          _ServiceCard(
            service: service,
            rooms: rooms.items,
            links: services.compatibility,
            onRetire: onRetire,
            onLink: onLink,
          ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Rooms & weekly hours',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: AppSpacing.sm),
        for (final room in rooms.items)
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(room.name, style: Theme.of(context).textTheme.titleMedium),
                Text(room.status),
                for (final hours in rooms.hours.where(
                  (item) => item.roomId == room.id,
                ))
                  Text(
                    '${_weekday(hours.weekday)} ${hours.opensAt}–${hours.closesAt}',
                  ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        const Text(
          'Historical bookings keep their original service, duration, and indicative price snapshots.',
        ),
      ],
    ),
  );
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.service,
    required this.rooms,
    required this.links,
    this.onRetire,
    this.onLink,
  });
  final CentreService service;
  final List<CentreRoom> rooms;
  final List<RoomServiceLink> links;
  final Future<void> Function(String serviceId)? onRetire;
  final Future<void> Function(String serviceId, String roomId)? onLink;

  @override
  Widget build(BuildContext context) {
    final linked = {
      for (final link in links.where(
        (link) => link.serviceId == service.id && link.unlinkedAt == null,
      ))
        link.roomId,
    };
    final format = NumberFormat.simpleCurrency(name: service.currencyCode);
    return AppCard(
      tone: CardTone.teal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  service.name,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Text(service.status),
            ],
          ),
          Text('${service.durationMinutes} min'),
          Text(
            '${format.format(service.indicativePriceMinor / 100)} indicative',
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            linked.isEmpty
                ? 'No compatible rooms'
                : 'Compatible: ${rooms.where((room) => linked.contains(room.id)).map((room) => room.name).join(', ')}',
          ),
          if (service.status == 'active')
            Wrap(
              spacing: AppSpacing.xs,
              children: [
                if (onLink != null &&
                    rooms.any((room) => !linked.contains(room.id)))
                  TextButton(
                    onPressed: () => _link(context, linked),
                    child: const Text('Link room'),
                  ),
                if (onRetire != null)
                  TextButton(
                    onPressed: () => onRetire!(service.id),
                    child: const Text('Retire'),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _link(BuildContext context, Set<String> linked) async {
    final candidates = rooms
        .where((room) => !linked.contains(room.id))
        .toList();
    final roomId = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Choose compatible room'),
        children: [
          for (final room in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, room.id),
              child: Text(room.name),
            ),
        ],
      ),
    );
    if (roomId != null) await onLink!(service.id, roomId);
  }
}

String _weekday(int weekday) => const [
  'Sun',
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
][weekday.clamp(0, 6)];
