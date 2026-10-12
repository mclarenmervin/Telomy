import 'package:flutter/foundation.dart';

/// Somewhere a person can say they are, to about 11km.
///
/// ── Why a city list and not GPS ─────────────────────────────────────────────
///
/// The server stores one decimal place, deliberately: a city, not a street.
/// Asking the operating system for a precise fix and then throwing five
/// decimals away is worse than asking the question we actually mean. It
/// needs a runtime permission, a platform plugin and a privacy disclosure,
/// and at the end of it the user has handed over their exact position and
/// has to trust us to have discarded most of it.
///
/// Picking a city has none of that. There is no permission to grant, nothing
/// precise ever exists on the device to leak, and the user can see exactly
/// what they shared because they chose it from a list. The thing we want —
/// which air-quality cell to look up — is answered just as well.
///
/// The cost is somebody in a town that is not listed, who picks the nearest
/// city instead. For an 11km lookup of regional air quality that is close to
/// free, and "the nearest of these" is what the screen asks for.
@immutable
class CoarsePlace {
  const CoarsePlace(this.name, this.region, this.latitude, this.longitude);

  final String name;

  /// What distinguishes two places with the same name, and what somebody
  /// scans for when the list is long.
  final String region;

  /// Already rounded to one decimal place. The server rounds again on
  /// arrival — the rule has to hold against our own app being wrong — but
  /// nothing more precise than this is ever stored on the device either.
  final double latitude;
  final double longitude;

  String get label => '$name, $region';
}

/// The places on offer.
///
/// Weighted to India because that is the market, with the handful of other
/// cities a user of an Indian health app is most likely to be living in.
/// Every coordinate is the city centre at one decimal place; it is a
/// lookup cell, not an address.
const coarsePlaces = <CoarsePlace>[
  CoarsePlace('Mumbai', 'Maharashtra', 19.1, 72.9),
  CoarsePlace('Delhi', 'Delhi', 28.6, 77.2),
  CoarsePlace('Bengaluru', 'Karnataka', 13.0, 77.6),
  CoarsePlace('Hyderabad', 'Telangana', 17.4, 78.5),
  CoarsePlace('Chennai', 'Tamil Nadu', 13.1, 80.3),
  CoarsePlace('Kolkata', 'West Bengal', 22.6, 88.4),
  CoarsePlace('Pune', 'Maharashtra', 18.5, 73.9),
  CoarsePlace('Ahmedabad', 'Gujarat', 23.0, 72.6),
  CoarsePlace('Jaipur', 'Rajasthan', 26.9, 75.8),
  CoarsePlace('Surat', 'Gujarat', 21.2, 72.8),
  CoarsePlace('Lucknow', 'Uttar Pradesh', 26.8, 80.9),
  CoarsePlace('Kanpur', 'Uttar Pradesh', 26.4, 80.3),
  CoarsePlace('Nagpur', 'Maharashtra', 21.1, 79.1),
  CoarsePlace('Indore', 'Madhya Pradesh', 22.7, 75.9),
  CoarsePlace('Bhopal', 'Madhya Pradesh', 23.3, 77.4),
  CoarsePlace('Visakhapatnam', 'Andhra Pradesh', 17.7, 83.2),
  CoarsePlace('Patna', 'Bihar', 25.6, 85.1),
  CoarsePlace('Vadodara', 'Gujarat', 22.3, 73.2),
  CoarsePlace('Ghaziabad', 'Uttar Pradesh', 28.7, 77.4),
  CoarsePlace('Ludhiana', 'Punjab', 30.9, 75.9),
  CoarsePlace('Coimbatore', 'Tamil Nadu', 11.0, 76.9),
  CoarsePlace('Kochi', 'Kerala', 10.0, 76.3),
  CoarsePlace('Chandigarh', 'Chandigarh', 30.7, 76.8),
  CoarsePlace('Guwahati', 'Assam', 26.1, 91.7),
  CoarsePlace('Bhubaneswar', 'Odisha', 20.3, 85.8),
  CoarsePlace('Thiruvananthapuram', 'Kerala', 8.5, 77.0),
  CoarsePlace('Mysuru', 'Karnataka', 12.3, 76.6),
  CoarsePlace('Nashik', 'Maharashtra', 20.0, 73.8),
  CoarsePlace('Dehradun', 'Uttarakhand', 30.3, 78.0),
  CoarsePlace('Panaji', 'Goa', 15.5, 73.8),
  CoarsePlace('London', 'United Kingdom', 51.5, -0.1),
  CoarsePlace('New York', 'United States', 40.7, -74.0),
  CoarsePlace('San Francisco', 'United States', 37.8, -122.4),
  CoarsePlace('Toronto', 'Canada', 43.7, -79.4),
  CoarsePlace('Dubai', 'United Arab Emirates', 25.2, 55.3),
  CoarsePlace('Singapore', 'Singapore', 1.3, 103.8),
  CoarsePlace('Sydney', 'Australia', -33.9, 151.2),
];

/// Places whose name or region matches, in list order.
List<CoarsePlace> searchPlaces(String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return coarsePlaces;
  return [
    for (final place in coarsePlaces)
      if (place.name.toLowerCase().contains(needle) ||
          place.region.toLowerCase().contains(needle))
        place,
  ];
}

/// The place a stored pair of coordinates came from, if it is still one of
/// ours.
///
/// Compared on the rounded value rather than by storing a name: the name is
/// a label and the coordinate is the fact, and a renamed city must not
/// orphan somebody's setting.
CoarsePlace? placeAt(double? latitude, double? longitude) {
  if (latitude == null || longitude == null) return null;
  for (final place in coarsePlaces) {
    if (place.latitude == latitude && place.longitude == longitude) {
      return place;
    }
  }
  return null;
}
