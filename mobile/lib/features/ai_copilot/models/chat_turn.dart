import 'package:flutter/foundation.dart';

/// One exchange with the concierge, as the phone sees it.
///
/// The phone renders a turn and never composes one. `answered` is the text the
/// server put through the emergency screen, the figure check and the
/// guardrails; rewording it here — even to tidy the spacing — would mean the
/// words on screen are not the words that were checked, recorded, and would be
/// produced if anybody ever asked what the product said to this person.
///
/// `route` is how the screen knows what kind of answer it is holding without
/// reading the text. It is deliberately a small closed set rather than the
/// server's guardrail flags, which stay on the server: a debug field on a
/// screen invites the user to ask why their answer was replaced, and that is a
/// conversation to have in the product's own words.
@immutable
class ChatTurn {
  const ChatTurn({
    required this.asked,
    required this.answered,
    required this.route,
    required this.quotedInsightIds,
    required this.createdAt,
  });

  /// The question, shown immediately while the answer is still in flight. The
  /// reply is never guessed at — there is no optimistic answer, because the
  /// only safe version of the answer is the one the server has checked.
  factory ChatTurn.pending(String asked) => ChatTurn(
        asked: asked,
        answered: '',
        route: pendingRoute,
        quotedInsightIds: const [],
        createdAt: null,
      );

  static const pendingRoute = 'pending';
  static const emergencyRoute = 'emergency';
  static const replacedRoute = 'guardrail_replaced';
  static const geneticRiskRoute = 'genetic_risk';

  final String asked;
  final String answered;
  final String route;

  /// Findings a clinician signed that this reply repeated word for word.
  final List<String> quotedInsightIds;

  final DateTime? createdAt;

  bool get isAwaitingAnswer => route == pendingRoute;

  /// The deterministic safety response fired before any model ran. The screen
  /// shows it prominently and offers no follow-up under it.
  bool get isEmergency => route == emergencyRoute;

  /// A rule replaced what the model said. Not labelled on screen — the
  /// fallback text says what it needs to — but the screen does not invite a
  /// follow-up on an answer the product declined to give.
  bool get wasReplaced => route == replacedRoute;

  /// A question about inherited disease risk, answered by a fixed sentence
  /// the server produced before any model ran.
  ///
  /// Rendered as an ordinary answer and deliberately NOT as an emergency: the
  /// red treatment is for something somebody may need to act on in the next
  /// few minutes, and "we never read those variants, and here is who can help
  /// you find out" is not that. The text explains itself in full, so it needs
  /// no label of its own — a badge saying "refused" would make an honest,
  /// complete answer read like a rebuff.
  bool get isGeneticRisk => route == geneticRiskRoute;

  bool get quotesSignedFinding => quotedInsightIds.isNotEmpty;

  /// A blank bubble reads as the product having nothing to say about somebody's
  /// health, so an unreadable row is left out of the conversation entirely.
  bool get isRenderable => asked.isNotEmpty && (answered.isNotEmpty || isAwaitingAnswer);

  static ChatTurn fromRow(Map<String, dynamic> row) => ChatTurn(
        asked: row['asked']?.toString() ?? '',
        answered: row['answered']?.toString() ?? '',
        route: row['route']?.toString() ?? '',
        quotedInsightIds: [
          for (final id in (row['quoted_insight_ids'] as List? ?? const []))
            id.toString(),
        ],
        createdAt: row['created_at'] == null
            ? null
            : DateTime.tryParse(row['created_at'].toString())?.toLocal(),
      );
}
