import 'package:flutter/material.dart';

import '../data/coarse_places.dart';

/// Choosing the city whose air we look up.
///
/// A list, not a map and not a GPS prompt. `coarse_places.dart` says why at
/// length; the short version is that the server stores about 11km, so asking
/// the operating system for an exact fix and discarding five decimals is a
/// permission, a plugin and a disclosure spent on throwing data away.
///
/// The sheet states what is shared before the list, not after it, and in the
/// terms the user can check: a city, roughly 11km, sent with nothing
/// attached to it.
Future<CoarsePlace?> pickCoarsePlace(BuildContext context) {
  return showModalBottomSheet<CoarsePlace>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _PlaceSheet(),
  );
}

class _PlaceSheet extends StatefulWidget {
  const _PlaceSheet();

  @override
  State<_PlaceSheet> createState() => _PlaceSheetState();
}

class _PlaceSheetState extends State<_PlaceSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = searchPlaces(_query);

    return SafeArea(
      child: Padding(
        // The keyboard, when the search field has focus.
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Which city are you usually in?',
                      key: const Key('place-picker-title'),
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'We look up the air quality and UV for that area. Only '
                      'the city is stored — about 11km, never your exact '
                      'position — and the lookup carries nothing that '
                      'identifies you.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('place-picker-search'),
                      autofocus: false,
                      decoration: const InputDecoration(
                        labelText: 'Search',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: matches.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                        child: Text(
                          'Nothing matches that. Pick the nearest listed city '
                          '— at this resolution the next one along is usually '
                          'the same air.',
                          key: const Key('place-picker-empty'),
                          style: theme.textTheme.bodyMedium,
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: matches.length,
                        itemBuilder: (context, index) {
                          final place = matches[index];
                          return ListTile(
                            key: Key('place-${place.name}'),
                            title: Text(place.name),
                            subtitle: Text(place.region),
                            onTap: () => Navigator.of(context).pop(place),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
