import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/widgets/async_action.dart';
import '../../journal/providers/wellness_provider.dart';
import '../data/marketplace_catalog.dart';

class MarketplaceScreen extends ConsumerStatefulWidget {
  const MarketplaceScreen({super.key});
  @override
  ConsumerState<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends ConsumerState<MarketplaceScreen> {
  String query = '';
  MarketplaceCategory? category;
  bool favoritesOnly = false;

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(wellnessProvider).asData?.value;
    final favorites = (data?.profile['marketplaceFavorites'] ?? '')
        .split(',')
        .where((item) => item.isNotEmpty)
        .toSet();
    final listings = MarketplaceCatalog.listings.where((item) {
      final matchesQuery =
          query.isEmpty ||
          item.name.toLowerCase().contains(query) ||
          item.provider.toLowerCase().contains(query);
      return matchesQuery &&
          (category == null || item.category == category) &&
          (!favoritesOnly || favorites.contains(item.id));
    }).toList();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Marketplace', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text(
          'Explore services that can support your personal wellness goals.',
        ),
        const SizedBox(height: 20),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Search services or providers',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) =>
              setState(() => query = value.trim().toLowerCase()),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('All'),
              selected: category == null && !favoritesOnly,
              onSelected: (_) => setState(() {
                category = null;
                favoritesOnly = false;
              }),
            ),
            for (final value in MarketplaceCategory.values)
              ChoiceChip(
                label: Text(_label(value.name)),
                selected: category == value && !favoritesOnly,
                onSelected: (_) => setState(() {
                  category = value;
                  favoritesOnly = false;
                }),
              ),
            ChoiceChip(
              label: const Text('Saved'),
              selected: favoritesOnly,
              onSelected: (_) => setState(() {
                category = null;
                favoritesOnly = true;
              }),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (listings.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(22),
              child: Text('No matching services.'),
            ),
          ),
        for (final listing in listings)
          Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _showDetails(
                context,
                listing,
                favorites.contains(listing.id),
              ),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Chip(label: Text(_label(listing.category.name))),
                        const Spacer(),
                        IconButton(
                          onPressed: data == null
                              ? null
                              : () => _toggleFavorite(listing.id, favorites),
                          icon: Icon(
                            favorites.contains(listing.id)
                                ? Icons.favorite
                                : Icons.favorite_border,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      listing.name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(listing.provider),
                    const SizedBox(height: 10),
                    Text(listing.description),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const Icon(Icons.star, size: 18),
                        Text(' ${listing.rating} (${listing.reviewCount})'),
                        const Spacer(),
                        Text(
                          '₹${listing.price.toStringAsFixed(0)}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _toggleFavorite(String id, Set<String> current) async {
    final data = await ref.read(wellnessProvider.future);
    if (!mounted) return;
    final next = {...current};
    next.contains(id) ? next.remove(id) : next.add(id);
    await runAction(
      context,
      () => ref.read(wellnessProvider.notifier).saveProfile({
        ...data.profile,
        'marketplaceFavorites': next.join(','),
      }),
    );
  }

  void _showDetails(
    BuildContext context,
    MarketplaceListing listing,
    bool saved,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                listing.name,
                style: Theme.of(sheetContext).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(listing.provider),
              const SizedBox(height: 16),
              Text(listing.description),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule),
                title: Text(listing.duration),
                subtitle: Text(listing.delivery),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.payments_outlined),
                title: Text('₹${listing.price.toStringAsFixed(0)}'),
                subtitle: const Text(
                  'Displayed price includes the listed session.',
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    context.push('/consultations');
                  },
                  child: const Text('View availability'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _label(String value) =>
      '${value[0].toUpperCase()}${value.substring(1)}';
}
