import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/ai_copilot/models/chat_turn.dart';

/// One exchange, as the phone sees it.
///
/// The phone renders a turn and never composes one: `answered` is the text the
/// server put through the guardrails, and rewording it here — even to tidy the
/// spacing — would mean the words on screen are not the words that were
/// checked, recorded and would be produced if anyone asked what the product
/// said.

Map<String, dynamic> row({
  String route = 'answered',
  List<String> flags = const [],
}) => {
      'asked': 'why is my readiness low?',
      'answered': 'Your readiness was 68 on 10 October.',
      'route': route,
      'guardrail_flags': flags,
      'created_at': '2026-10-11T09:00:00Z',
    };

void main() {
  test('a turn carries what was asked and what was answered', () {
    final turn = ChatTurn.fromRow(row());

    expect(turn.asked, 'why is my readiness low?');
    expect(turn.answered, 'Your readiness was 68 on 10 October.');
  });

  test('an emergency turn is marked so the screen can treat it differently', () {
    expect(ChatTurn.fromRow(row(route: 'emergency')).isEmergency, isTrue);
    expect(ChatTurn.fromRow(row()).isEmergency, isFalse);
  });

  test('a replaced answer is known to be one', () {
    /// Not to label it on screen — the fallback text says what it needs to —
    /// but so the screen does not invite a follow-up on an answer the product
    /// declined to give.
    expect(ChatTurn.fromRow(row(route: 'guardrail_replaced')).wasReplaced, isTrue);
  });

  test('an answer that quotes a signed finding says so', () {
    final turn = ChatTurn.fromRow({
      ...row(),
      'quoted_insight_ids': ['aaaaaaaa-0000-4000-8000-00000000000a'],
    });

    expect(turn.quotesSignedFinding, isTrue);
    expect(turn.quotedInsightIds, hasLength(1));
  });

  test('a turn with no quotes claims none', () {
    expect(ChatTurn.fromRow(row()).quotesSignedFinding, isFalse);
  });

  test('a row with a missing answer does not render as an empty bubble', () {
    /// A blank bubble reads as the product having nothing to say about
    /// somebody's health. An unreadable row is better left out of the
    /// conversation entirely.
    expect(ChatTurn.fromRow({...row(), 'answered': null}).isRenderable, isFalse);
    expect(ChatTurn.fromRow(row()).isRenderable, isTrue);
  });

  test('times are local, because the conversation is read at a wall clock', () {
    final turn = ChatTurn.fromRow(row());

    expect(turn.createdAt!.isUtc, isFalse);
  });

  test('a pending turn is the question before the answer arrives', () {
    /// So the message appears the instant it is sent rather than after the
    /// round trip. The reply is never guessed at.
    final pending = ChatTurn.pending('what about my magnesium?');

    expect(pending.asked, 'what about my magnesium?');
    expect(pending.answered, isEmpty);
    expect(pending.isAwaitingAnswer, isTrue);
    expect(ChatTurn.fromRow(row()).isAwaitingAnswer, isFalse);
  });
}
