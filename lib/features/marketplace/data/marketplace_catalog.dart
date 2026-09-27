enum MarketplaceCategory { coaching, nutrition, recovery, diagnostics, fitness }

class MarketplaceListing {
  const MarketplaceListing({
    required this.id,
    required this.name,
    required this.provider,
    required this.category,
    required this.description,
    required this.price,
    required this.duration,
    required this.rating,
    required this.reviewCount,
    required this.delivery,
  });
  final String id, name, provider, description, duration, delivery;
  final MarketplaceCategory category;
  final double price, rating;
  final int reviewCount;
}

abstract final class MarketplaceCatalog {
  static const listings = <MarketplaceListing>[
    MarketplaceListing(
      id: 'nutrition-review',
      name: 'Nutrition review',
      provider: 'Telomy Nutrition Network',
      category: MarketplaceCategory.nutrition,
      description:
          'A structured review of food logs, goals, and practical meal planning.',
      price: 1499,
      duration: '45 min',
      rating: 4.8,
      reviewCount: 126,
      delivery: 'Video consultation',
    ),
    MarketplaceListing(
      id: 'fitness-planning',
      name: 'Training plan consultation',
      provider: 'Telomy Coach Network',
      category: MarketplaceCategory.fitness,
      description:
          'Review recent training and create a progressive four-week plan.',
      price: 1799,
      duration: '50 min',
      rating: 4.7,
      reviewCount: 94,
      delivery: 'Video consultation',
    ),
    MarketplaceListing(
      id: 'sleep-coaching',
      name: 'Sleep routine coaching',
      provider: 'Rest Well Collective',
      category: MarketplaceCategory.coaching,
      description:
          'A non-clinical session focused on routines and sleep consistency.',
      price: 1299,
      duration: '40 min',
      rating: 4.9,
      reviewCount: 81,
      delivery: 'Video consultation',
    ),
    MarketplaceListing(
      id: 'recovery-session',
      name: 'Mobility and recovery session',
      provider: 'Move Better Studio',
      category: MarketplaceCategory.recovery,
      description: 'Guided mobility session adapted to your recent activity.',
      price: 999,
      duration: '30 min',
      rating: 4.6,
      reviewCount: 67,
      delivery: 'Live online session',
    ),
    MarketplaceListing(
      id: 'lab-review',
      name: 'Lab report organization',
      provider: 'Health Records Desk',
      category: MarketplaceCategory.diagnostics,
      description:
          'Help digitizing report values and preparing questions for your clinician.',
      price: 799,
      duration: '25 min',
      rating: 4.5,
      reviewCount: 43,
      delivery: 'Secure online session',
    ),
  ];
}
