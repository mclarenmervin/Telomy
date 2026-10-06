import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/scores/data/score_source.dart';
import 'package:telomy/features/scores/widgets/score_origin_note.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('a server score says it used the full history', (tester) async {
    await tester.pumpWidget(host(const ScoreOriginNote(
      resolved: ResolvedScore(
        origin: ScoreOrigin.server, value: 72, modelVersion: 'readiness-v1'),
    )));

    expect(find.textContaining('full history'), findsOneWidget);
  });

  testWidgets('an offline estimate says so rather than passing as the real one',
      (tester) async {
    await tester.pumpWidget(host(const ScoreOriginNote(
      resolved: ResolvedScore(
        origin: ScoreOrigin.offline, value: 68, modelVersion: offlineModelVersion),
    )));

    expect(find.textContaining('Estimated on this phone'), findsOneWidget);
  });

  testWidgets('no score at all says there is not enough data, not zero',
      (tester) async {
    await tester.pumpWidget(host(const ScoreOriginNote(
      resolved: ResolvedScore(
        origin: ScoreOrigin.none, value: null, modelVersion: offlineModelVersion),
    )));

    expect(find.textContaining('Not enough data'), findsOneWidget);
    expect(find.textContaining('0'), findsNothing);
  });

  testWidgets('divergence is hidden from users in a normal build', (tester) async {
    await tester.pumpWidget(host(const ScoreOriginNote(
      resolved: ResolvedScore(
        origin: ScoreOrigin.offline, value: 68, modelVersion: offlineModelVersion),
      divergence: 4,
    )));

    expect(find.textContaining('server +4'), findsNothing);
  });
}
