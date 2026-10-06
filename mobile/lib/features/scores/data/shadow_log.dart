import 'package:flutter/foundation.dart';

/// Evidence for the decision to stop computing scores on the phone.
///
/// The server number is computed and compared, but the app keeps displaying the
/// local one until the two have agreed for the whole window. That is what makes
/// the switch a measured decision rather than a hopeful one — and it is why
/// this records days rather than samples: a screen that rebuilds forty times
/// today is not forty pieces of evidence.
///
/// Two rules carry most of the value:
///
/// *A day with no comparison is not a clean day.* Absence of evidence is not
/// evidence of agreement, and a user who was offline all week must not look
/// like a successful shadow run.
///
/// *One disagreement blocks the switch permanently.* It must be explained and
/// the window restarted, not waited out — a divergence that stops appearing is
/// usually a divergence that stopped being looked at.
@immutable
class _Day {
  const _Day(this.kind, this.day);
  final String kind;
  final DateTime day;

  @override
  bool operator ==(Object other) =>
      other is _Day &&
      other.kind == kind &&
      other.day.year == day.year &&
      other.day.month == day.month &&
      other.day.day == day.day;

  @override
  int get hashCode => Object.hash(kind, day.year, day.month, day.day);
}

class ShadowLog {
  ShadowLog({this.requiredCleanDays = 14});

  /// How long the two must agree before the app shows the server's number.
  final int requiredCleanDays;

  final Map<_Day, int> _divergences = {};

  void record({
    required String kind,
    required DateTime day,
    required int? divergence,
  }) {
    // No comparison is no evidence — recording it as agreement is the one way
    // this log could lie.
    if (divergence == null) return;
    _divergences[_Day(kind, day)] = divergence;
  }

  Iterable<int> get _values => _divergences.values;

  int get cleanDays => _values.where((d) => d == 0).length;
  int get divergentDays => _values.where((d) => d != 0).length;

  /// The largest disagreement by magnitude, keeping its sign — a number that is
  /// consistently four points low is a different bug from one that is noisy.
  int? get worstDivergence {
    if (_values.isEmpty) return null;
    return _values.reduce((a, b) => a.abs() >= b.abs() ? a : b);
  }

  bool get isClean => _values.isNotEmpty && divergentDays == 0;

  bool get isReadyToSwitch => isClean && cleanDays >= requiredCleanDays;
}
