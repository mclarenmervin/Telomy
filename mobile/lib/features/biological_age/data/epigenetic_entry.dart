import '../models/epigenetic_clock.dart';

/// Checking a clock result the user is typing in.
///
/// This is the one place in the feature where a number originates on the phone
/// rather than arriving from the server, so it is the one place that needs
/// input validation at all. The rest of the biological-age feature renders what
/// it is given.
///
/// The bar is deliberately low: we are not judging whether a result is good,
/// only whether it is a plausible transcription of one. A clock result is
/// somebody else's measurement and we have no basis to second-guess it -- but a
/// 413 typed for 41.3 would sit on a chart beside a real result looking exactly
/// like a measurement, and that is worth catching.

/// Ages, in years. Generous on both ends: an epigenetic age can sit well away
/// from chronological age, which is the entire point of measuring one.
const _minAge = 1.0;
const _maxAge = 120.0;

/// DunedinPACE is years of biological ageing per calendar year. Published
/// cohorts sit roughly between 0.6 and 1.8; this is wider still, because
/// refusing somebody's real result is worse than accepting an odd one.
const _minPace = 0.3;
const _maxPace = 3.0;

/// Horvath published the first multi-tissue clock in 2013. A result dated
/// before that is a mistyped year, not a very early adopter.
final _earliestPlausible = DateTime.utc(2013, 1, 1);

/// The unit a clock reports in.
///
/// Derived, never asked. Offering a unit picker invites someone to record a
/// rate as an age, which is precisely the confusion this feature has to avoid.
String unitFor(String clock) => clock == 'dunedinpace' ? 'pace' : 'years';

bool _isPace(String clock) => unitFor(clock) == 'pace';

/// Field name -> what is wrong with it. Empty means the entry is usable.
///
/// Every problem is reported at once. A form that reveals one error at a time
/// makes someone submit repeatedly just to find out what it wants.
Map<String, String> validateClockEntry({
  required String clock,
  required String value,
  required String provider,
  required DateTime collectedAt,
  required DateTime today,
}) {
  final errors = <String, String>{};

  if (!knownClocks.contains(clock)) {
    errors['clock'] = 'Choose one of the clocks we can display.';
  }

  final parsed = double.tryParse(value.trim());
  if (parsed == null) {
    errors['value'] = 'Enter the result as a number.';
  } else if (parsed <= 0) {
    errors['value'] = 'A result has to be greater than zero.';
  } else if (_isPace(clock)) {
    if (parsed < _minPace || parsed > _maxPace) {
      errors['value'] =
          'DunedinPACE is a rate of ageing, usually near 1. Check the figure.';
    }
  } else if (parsed < _minAge || parsed > _maxAge) {
    errors['value'] = 'That is outside a human lifespan. Check the figure.';
  }

  if (provider.trim().isEmpty) {
    // Without this the number reads as ours, which is the one thing it must
    // never do.
    errors['provider'] = 'Tell us who measured it.';
  }

  final day = DateTime.utc(collectedAt.year, collectedAt.month, collectedAt.day);
  final now = DateTime.utc(today.year, today.month, today.day);
  if (day.isAfter(now)) {
    errors['collectedAt'] = 'A sample cannot have been taken in the future.';
  } else if (day.isBefore(_earliestPlausible)) {
    errors['collectedAt'] = 'Check the year — that is before these tests existed.';
  }

  return errors;
}
