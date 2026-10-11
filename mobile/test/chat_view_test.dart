import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/ai_copilot/data/chat_repository.dart';
import 'package:telomy/features/ai_copilot/models/chat_turn.dart';
import 'package:telomy/features/ai_copilot/widgets/chat_view.dart';

/// The conversation on screen.
///
/// The screen renders what the server said and never composes an answer of its
/// own, so most of what is worth testing here is about the moments in between:
/// what the user sees while they wait, what happens when nothing comes back,
/// and whether a refusal can be mistaken for an answer.

ChatTurn answered({
  String asked = 'why is my readiness low?',
  String answer = 'Your readiness was 68 on 10 October.',
  String route = 'answered',
  List<String> quoted = const [],
}) => ChatTurn(
      asked: asked,
      answered: answer,
      route: route,
      quotedInsightIds: quoted,
      createdAt: DateTime(2026, 10, 11, 9),
    );

Future<void> pump(
  WidgetTester tester, {
  List<ChatTurn> history = const [],
  Future<ChatTurn> Function(String)? onAsk,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatView(
          history: history,
          onAsk: onAsk ?? (asked) async => answered(asked: asked),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final field = find.byKey(const Key('chat-input'));
final send = find.byKey(const Key('chat-send'));

Future<void> ask(WidgetTester tester, String message) async {
  await tester.enterText(field, message);
  await tester.tap(send);
  await tester.pump();
}

void main() {
  testWidgets('the conversation so far is shown', (tester) async {
    await pump(tester, history: [answered()]);

    expect(find.text('why is my readiness low?'), findsOneWidget);
    expect(find.text('Your readiness was 68 on 10 October.'), findsOneWidget);
  });

  testWidgets('the question appears before the answer does', (tester) async {
    /// The one thing the phone may render without the server. Waiting for the
    /// round trip to show your own words makes the product feel broken.
    final pending = Completer<ChatTurn>();
    await pump(tester, onAsk: (asked) => pending.future);

    await ask(tester, 'what about my magnesium?');

    expect(find.text('what about my magnesium?'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    pending.complete(answered(asked: 'what about my magnesium?', answer: 'Here it is.'));
    await tester.pumpAndSettle();
    expect(find.text('Here it is.'), findsOneWidget);
  });

  testWidgets('a second question cannot be sent while one is in flight',
      (tester) async {
    /// Every turn costs a model call and counts against the daily cap, so a
    /// double tap must not spend two of them.
    var calls = 0;
    final pending = Completer<ChatTurn>();
    await pump(tester, onAsk: (asked) {
      calls += 1;
      return pending.future;
    });

    await ask(tester, 'how am I doing?');
    await tester.tap(send, warnIfMissed: false);
    await tester.pump();

    expect(calls, 1);
    pending.complete(answered());
    await tester.pumpAndSettle();
  });

  testWidgets('an empty message is not sent', (tester) async {
    var calls = 0;
    await pump(tester, onAsk: (asked) async {
      calls += 1;
      return answered();
    });

    await ask(tester, '   ');

    expect(calls, 0);
  });

  testWidgets('a failure is explained and the question is not lost',
      (tester) async {
    /// Retyping a question the product failed to answer is the kind of small
    /// insult that stops people using a feature.
    await pump(
      tester,
      onAsk: (asked) async => throw const ChatUnavailable('No connection.'),
    );

    await ask(tester, 'how am I doing?');
    await tester.pumpAndSettle();

    expect(find.textContaining('No connection.'), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, 'how am I doing?');
  });

  testWidgets('an emergency answer is shown urgently and invites no follow-up',
      (tester) async {
    await pump(tester, history: [
      answered(
        asked: "I can't breathe",
        answer: 'What you have described needs urgent medical attention.',
        route: ChatTurn.emergencyRoute,
      ),
    ]);

    expect(find.byKey(const Key('chat-emergency')), findsOneWidget);
    expect(find.byKey(const Key('chat-suggestions')), findsNothing);
  });

  testWidgets('an answer that repeats a signed finding says who stands behind it',
      (tester) async {
    await pump(tester, history: [
      answered(answer: 'The finding reads: ...', quoted: const ['f1']),
    ]);

    expect(find.textContaining('a clinician signed'), findsOneWidget);
  });

  testWidgets('an ordinary answer claims no clinician', (tester) async {
    /// The note is the whole value of the quoting path, so it must appear only
    /// where a clinician's words actually did. The screen's standing
    /// disclaimer mentions clinicians either way, which is why this looks for
    /// the note and not for the word.
    await pump(tester, history: [answered()]);

    expect(find.textContaining('a clinician signed'), findsNothing);
  });

  testWidgets('suggestions are offered only before the conversation starts',
      (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('chat-suggestions')), findsOneWidget);

    await pump(tester, history: [answered()]);
    expect(find.byKey(const Key('chat-suggestions')), findsNothing);
  });

  testWidgets('tapping a suggestion asks it', (tester) async {
    String? askedWith;
    await pump(tester, onAsk: (asked) async {
      askedWith = asked;
      return answered(asked: asked);
    });

    await tester.tap(find.byKey(const Key('chat-suggestions')).first);
    await tester.pumpAndSettle();

    expect(askedWith, isNotNull);
  });

  testWidgets('the screen says it is not a clinician', (tester) async {
    /// On the screen itself, not only in the answers. A conversational
    /// interface invites medical questions, and the standing limit should not
    /// depend on the model remembering to mention it.
    await pump(tester);

    expect(find.textContaining('not a'), findsWidgets);
  });
}
