import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/ai_copilot/data/chat_repository.dart';

/// Asking a question, and what the phone does with each kind of answer.
///
/// The write goes over REST because it is the one thing on this screen the
/// phone cannot do for itself: the answer has to be produced, grounded and
/// guarded on the server. History is read from Supabase like every other table
/// the app reads, which is why there is no history call here.

class StubAdapter implements HttpClientAdapter {
  StubAdapter({this.status = 200, Map<String, dynamic>? body})
      : body = body ?? {'answer': 'Your readiness was 68.', 'route': 'answered'};

  int status;
  Map<String, dynamic> body;
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ChatRepository repositoryWith(StubAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8000'));
  dio.httpClientAdapter = adapter;
  return ChatRepository(http: dio);
}

void main() {
  test('a question is posted and the answer comes back as a turn', () async {
    final adapter = StubAdapter();

    final turn = await repositoryWith(adapter).ask('why is my readiness low?');

    expect(adapter.lastRequest!.path, '/api/v1/chat');
    expect(adapter.lastRequest!.data, {'message': 'why is my readiness low?'});
    expect(turn.answered, 'Your readiness was 68.');
    expect(turn.asked, 'why is my readiness low?');
  });

  test('the request carries no user id', () async {
    /// The caller comes from the token. A user id in the body would be
    /// something to tamper with, and the server ignores it anyway.
    final adapter = StubAdapter();

    await repositoryWith(adapter).ask('how am I doing?');

    expect((adapter.lastRequest!.data as Map).keys, ['message']);
  });

  test('an emergency answer keeps its route', () async {
    final adapter = StubAdapter(body: {
      'answer': 'What you have described needs urgent medical attention.',
      'route': 'emergency',
    });

    final turn = await repositoryWith(adapter).ask("I can't breathe");

    expect(turn.isEmergency, isTrue);
  });

  test('a quoted finding is carried through to the screen', () async {
    final adapter = StubAdapter(body: {
      'answer': 'The finding reads: ...',
      'route': 'answered',
      'quoted_insight_ids': ['aaaaaaaa-0000-4000-8000-00000000000a'],
    });

    final turn = await repositoryWith(adapter).ask('what did the doctor say?');

    expect(turn.quotesSignedFinding, isTrue);
  });

  test('the daily limit is a message, not a crash', () async {
    /// A 429 is the one refusal a well-behaved client can provoke, and the
    /// person reading it has done nothing wrong.
    final adapter = StubAdapter(
      status: 429,
      body: {'detail': "you have reached today's limit for questions."},
    );

    expect(
      () => repositoryWith(adapter).ask('again?'),
      throwsA(isA<ChatUnavailable>().having(
        (e) => e.message,
        'message',
        contains('limit'),
      )),
    );
  });

  test('a server error does not surface as a Dio exception', () async {
    /// The screen should never have to know what Dio is, and "DioException
    /// [bad response]" is not something to show somebody asking about their
    /// blood test.
    final adapter = StubAdapter(status: 500, body: {});

    expect(
      () => repositoryWith(adapter).ask('how am I doing?'),
      throwsA(isA<ChatUnavailable>()),
    );
  });

  test('a reply with no answer in it is not shown as an answer', () async {
    final adapter = StubAdapter(body: {'route': 'answered'});

    expect(
      () => repositoryWith(adapter).ask('how am I doing?'),
      throwsA(isA<ChatUnavailable>()),
    );
  });

  test('without an API client the screen is told, not left waiting', () async {
    expect(
      () => ChatRepository().ask('how am I doing?'),
      throwsA(isA<ChatUnavailable>()),
    );
  });
}
