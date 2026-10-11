import 'package:dio/dio.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/supabase_config.dart';
import '../models/chat_turn.dart';

/// Something stopped the question being answered, phrased for a person.
///
/// The screen should never have to know what Dio is. "DioException [bad
/// response]" is not a thing to show somebody who just asked about their blood
/// test, and a 429 is not an error at all — it is the product saying it has
/// answered enough for today.
class ChatUnavailable implements Exception {
  const ChatUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Talking to the concierge.
///
/// **Asking goes over REST.** It is the one thing on this screen the phone
/// cannot do for itself: the answer has to be produced from the user's own
/// data, grounded in tool calls, and put through the guardrails, and all three
/// of those live on the server. There is no AI provider key in this app and
/// there never will be.
///
/// **Reading the conversation back comes from Supabase**, like scores, lab
/// uploads and insights. `chat_turns` has one policy and it admits exactly the
/// owner, so the isolation is the database's rather than ours to remember. It
/// also means the history is there on a cold start before the API is reachable.
class ChatRepository {
  ChatRepository({SupabaseClient? client, Dio? http})
      : _client = client,
        _http = http;

  final SupabaseClient? _client;
  final Dio? _http;

  SupabaseClient? get _db {
    if (!SupabaseConfig.configured) return null;
    return _client ?? Supabase.instance.client;
  }

  /// The conversation so far, oldest first — which is the order it is read in.
  Future<List<ChatTurn>> history({required String userId, int limit = 30}) async {
    final db = _db;
    if (db == null) return const [];
    try {
      final rows = await db
          .from('chat_turns')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(limit);
      final turns = [
        for (final row in rows) ChatTurn.fromRow(Map<String, dynamic>.from(row)),
      ].where((turn) => turn.isRenderable).toList();
      return turns.reversed.toList();
    } catch (_) {
      // Offline. An empty conversation is the honest rendering of "we could
      // not look": the screen says nothing about history rather than claiming
      // there is none.
      return const [];
    }
  }

  /// Ask a question and get the answer the server has already checked.
  Future<ChatTurn> ask(String message) async {
    final http = _http;
    if (http == null) {
      throw const ChatUnavailable(
        'Chat needs the Telomy service, which this build is not pointed at.',
      );
    }

    final Response<dynamic> response;
    try {
      response = await http.post(
        '/api/v1/chat',
        data: {'message': message},
        // A turn runs the model and its tools, which is slower than every
        // other call this app makes, and `wall_clock_seconds` already bounds
        // it on the server.
        options: Options(
          receiveTimeout: const Duration(seconds: 90),
          validateStatus: (status) => status != null && status < 500,
        ),
      );
    } on DioException catch (error) {
      throw ChatUnavailable(_offlineMessage(error));
    }

    final body = response.data is Map
        ? Map<String, dynamic>.from(response.data as Map)
        : const <String, dynamic>{};

    if (response.statusCode != 200) {
      // The server's own words where it gave them: it knows whether this was a
      // daily limit or a question it would not take.
      throw ChatUnavailable(
        body['detail']?.toString() ?? 'That question could not be answered.',
      );
    }

    final answer = body['answer']?.toString() ?? '';
    if (answer.isEmpty) {
      // A blank bubble reads as the product having nothing to say about this
      // person's health.
      throw ChatUnavailable('No answer came back. Please try again.');
    }

    return ChatTurn(
      asked: message,
      answered: answer,
      route: body['route']?.toString() ?? 'answered',
      quotedInsightIds: [
        for (final id in (body['quoted_insight_ids'] as List? ?? const []))
          id.toString(),
      ],
      createdAt: DateTime.now(),
    );
  }

  String _offlineMessage(DioException error) =>
      switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout =>
          'That took too long to come back. Please try again.',
        DioExceptionType.connectionError =>
          'No connection, so I could not look anything up.',
        _ => 'That question could not be answered just now.',
      };
}
