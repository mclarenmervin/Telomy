import 'package:flutter/foundation.dart';

import '../models/score_snapshot.dart';

/// Where a number on screen came from.
///
/// The distinction is load-bearing. An offline estimate is a *different number*
/// computed by a frozen local model, not a stand-in for the server's. Tagging
/// it in the type — rather than trusting every call site to remember — is what
/// stops the dual-math defect reappearing the moment someone is on a train.
enum ScoreOrigin { server, offline, none }

/// The local fallback's own version string, deliberately distinct from any
/// server model version so the two can never be confused in a screenshot or a
/// support conversation.
const offlineModelVersion = 'readiness-offline-estimate-v1';

@immutable
class ResolvedScore {
  const ResolvedScore({
    required this.origin,
    required this.value,
    required this.modelVersion,
    this.snapshot,
  });

  final ScoreOrigin origin;
  final int? value;
  final String modelVersion;

  /// Present only for a server score — the offline path has no provenance to
  /// show, which is itself worth showing.
  final ScoreSnapshot? snapshot;

  bool get isOffline => origin == ScoreOrigin.offline;
  bool get isEmpty => origin == ScoreOrigin.none;
}

bool _covers(ScoreSnapshot snapshot, DateTime day) =>
    snapshot.asOf.year == day.year &&
    snapshot.asOf.month == day.month &&
    snapshot.asOf.day == day.day;

/// Which number to show for a day.
///
/// The server's wins whenever it has one for that day. A snapshot for another
/// day is not a fallback — showing Tuesday's readiness on Thursday is worse
/// than showing a clearly-labelled local estimate.
ResolvedScore resolveScore({
  required ScoreSnapshot? server,
  required int? offline,
  required DateTime forDay,
}) {
  if (server != null && server.hasValue && _covers(server, forDay)) {
    return ResolvedScore(
      origin: ScoreOrigin.server,
      value: server.value,
      modelVersion: server.modelVersion,
      snapshot: server,
    );
  }
  if (offline != null) {
    return ResolvedScore(
      origin: ScoreOrigin.offline,
      value: offline,
      modelVersion: offlineModelVersion,
    );
  }
  return const ResolvedScore(
    origin: ScoreOrigin.none,
    value: null,
    modelVersion: offlineModelVersion,
  );
}

/// How far the local estimate sits from the server's number, signed.
///
/// Signed on purpose: a server number consistently four points low is a
/// different bug from one that is noisy in both directions, and during the
/// shadow period that distinction is the whole signal.
int? divergenceBetween({
  required ScoreSnapshot? server,
  required int? offline,
}) {
  if (server?.value == null || offline == null) return null;
  return server!.value! - offline;
}
