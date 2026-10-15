import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/vocabulary.dart';
import '../models/therapy_catalogue.dart';
import '../providers/therapy_provider.dart';

class TherapyCatalogueScreen extends ConsumerWidget {
  const TherapyCatalogueScreen({super.key, this.initialItems, this.initialOfferings = const []});
  final List<TherapyCatalogueItem>? initialItems;
  final List<TherapyOffering> initialOfferings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = initialItems == null ? ref.watch(therapyCatalogueProvider) : null;
    final items = initialItems ?? async?.asData?.value;
    return AppScreen(title: 'Therapies', children: [
      const T('Explore what is available, then review the safety details before adding anything to a plan.', muted: true),
      const SizedBox(height: AppSpacing.lg),
      if (items == null && async?.isLoading == true) const Loading('Loading therapies…')
      else if (items == null) ErrorState(message: 'The therapy catalogue is unavailable.', onRetry: () => ref.invalidate(therapyCatalogueProvider))
      else if (items.isEmpty) const Empty(title: 'No therapies available', body: 'Published therapies will appear here.', tone: EmptyTone.waiting)
      else for (final item in items) _CatalogueRow(item: item, offering: initialOfferings.where((value) => value.catalogueId == item.id).firstOrNull),
    ]);
  }
}

class _CatalogueRow extends StatelessWidget {
  const _CatalogueRow({required this.item, this.offering});
  final TherapyCatalogueItem item;
  final TherapyOffering? offering;
  @override Widget build(BuildContext context) => AppCard(
    onTap: () => context.push('/therapies/${item.id}', extra: item),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Expanded(child: T(item.name, v: TextVariant.h3)), const Icon(Icons.chevron_right)]),
      const SizedBox(height: AppSpacing.xxs), T(item.summary, muted: true),
      if (offering != null) ...[const SizedBox(height: AppSpacing.sm), Text(offering!.indicativePrice, style: Theme.of(context).textTheme.labelLarge)],
    ]),
  );
}
