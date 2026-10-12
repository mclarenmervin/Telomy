import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/app/theme/app_theme.dart';
import 'package:telomy/core/vocabulary/vocabulary.dart';

/// The fourteen pieces every later phase builds from.
///
/// The tests that matter are the ones about [Prov], [ConfBar] and [Empty],
/// because those three are where this product is most likely to lie:
///
///   * a number with no source is the thing F9 exists to make impossible, so
///     `Prov` cannot be constructed without one;
///   * a confidence expressed as a bar with no reason under it is a number we
///     invented, so `ConfBar` requires its basis and renders no percentage;
///   * an `Empty` that is a shrug reads as a broken feature, and three phases
///     from now the therapy tab's commonest state is "no reliable signal yet".
Widget host(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: AppTheme.build(brightness),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('T', () {
    testWidgets('renders its text at the variant it was given', (tester) async {
      await tester.pumpWidget(host(const Column(children: [
        T('A heading', v: TextVariant.h1),
        T('43.2', v: TextVariant.num),
      ])));

      expect(find.text('A heading'), findsOneWidget);
      final number = tester.widget<Text>(find.text('43.2'));
      expect(number.style?.fontFeatures?.map((f) => f.feature),
          contains('tnum'));
    });
  });

  group('Prov', () {
    testWidgets('says where a number came from, when, and how good it is',
        (tester) async {
      await tester.pumpWidget(host(Prov(
        source: 'open-meteo',
        when: DateTime(2026, 10, 11),
        confidence: Confidence.measured,
        basis: '24 hours observed',
      )));

      final text = find.byType(Text).evaluate()
          .map((e) => (e.widget as Text).data)
          .join(' · ');
      expect(text, contains('open-meteo'));
      expect(text, contains('11 Oct 2026'));
      expect(text, contains('24 hours observed'));
    });

    testWidgets('states the confidence in words and not only as a colour',
        (tester) async {
      await tester.pumpWidget(host(const Prov(
        source: 'your ring',
        confidence: Confidence.estimated,
        basis: 'partial night',
      )));

      expect(find.textContaining('Estimated'), findsOneWidget);
    });

    testWidgets('a number whose explanation nobody has reviewed says so',
        (tester) async {
      // The sentence already written by hand on four screens, now one thing.
      await tester.pumpWidget(host(const Prov(
        source: 'your own sessions',
        confidence: Confidence.unreviewed,
        basis: 'across 8 sessions',
      )));

      expect(find.textContaining('Nobody has reviewed'), findsOneWidget);
    });

    testWidgets('renders without a date, because some numbers are a window',
        (tester) async {
      await tester.pumpWidget(host(const Prov(
        source: 'your last 60 days',
        confidence: Confidence.measured,
        basis: '60 matching days',
      )));

      expect(find.textContaining('your last 60 days'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a window can be given in words instead of a date',
        (tester) async {
      await tester.pumpWidget(host(const Prov(
        source: 'your ring',
        whenLabel: 'the last 7 days',
        confidence: Confidence.measured,
        basis: '7 nights',
      )));

      expect(find.textContaining('the last 7 days'), findsOneWidget);
    });

    testWidgets('a simulated number is labelled simulated', (tester) async {
      // Decision 5. The token exists in F9 and so does the only component
      // that can render a number's provenance, so F13 has no excuse.
      await tester.pumpWidget(host(const Prov(
        source: 'a literature model',
        confidence: Confidence.simulated,
        basis: 'not measured on you',
      )));

      expect(find.textContaining('Simulated'), findsOneWidget);
      expect(find.textContaining('not measured on you'), findsOneWidget);
    });

    testWidgets('is legible in the dark as well', (tester) async {
      await tester.pumpWidget(host(
        const Prov(
          source: 'open-meteo',
          confidence: Confidence.measured,
          basis: '24 hours observed',
        ),
        brightness: Brightness.dark,
      ));

      expect(find.textContaining('open-meteo'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('ConfBar', () {
    testWidgets('always shows what the confidence rests on', (tester) async {
      await tester.pumpWidget(host(const ConfBar(
        confidence: Confidence.measured,
        basis: '60 matching days',
      )));

      expect(find.text('60 matching days'), findsOneWidget);
    });

    testWidgets('never renders a percentage', (tester) async {
      // A 0-1 confidence would be a number nobody computed. What we have is
      // an evidence count -- days, sessions, hours observed -- and turning
      // that into 73% is exactly the manufacturing this codebase refuses.
      for (final confidence in Confidence.values) {
        await tester.pumpWidget(host(ConfBar(
          confidence: confidence,
          basis: 'some basis',
        )));

        final text = find.byType(Text).evaluate()
            .map((e) => (e.widget as Text).data ?? '')
            .join(' ');
        expect(text.contains('%'), isFalse, reason: confidence.name);
      }
    });

    testWidgets('fills more of the bar for stronger evidence', (tester) async {
      Future<int> filled(Confidence confidence) async {
        await tester.pumpWidget(host(ConfBar(
          confidence: confidence,
          basis: 'basis',
        )));
        return tester
            .widgetList<ConfSegment>(find.byType(ConfSegment))
            .where((s) => s.filled)
            .length;
      }

      expect(await filled(Confidence.insufficient),
          lessThan(await filled(Confidence.estimated)));
      expect(await filled(Confidence.estimated),
          lessThan(await filled(Confidence.measured)));
    });

    testWidgets('an unreviewed explanation is not weak evidence',
        (tester) async {
      // Two different axes, and conflating them is the mistake. "We measured
      // this across 8 sessions" can be strong evidence whose *explanation*
      // nobody has signed; showing it as low confidence would be telling
      // somebody their own data is unreliable.
      await tester.pumpWidget(host(const ConfBar(
        confidence: Confidence.unreviewed,
        basis: 'across 8 sessions',
      )));

      expect(find.textContaining('across 8 sessions'), findsOneWidget);
      expect(find.byType(ConfSegment), findsNothing);
    });
  });

  group('StatusChip', () {
    testWidgets('renders the word for the status', (tester) async {
      await tester.pumpWidget(host(const StatusChip(AppStatus.awaitingClinician)));

      expect(find.text('Awaiting clinician'), findsOneWidget);
    });

    testWidgets('can carry its own wording when the default is too generic',
        (tester) async {
      await tester.pumpWidget(
          host(const StatusChip(AppStatus.notReviewed, label: 'Not graded')));

      expect(find.text('Not graded'), findsOneWidget);
    });
  });

  group('Stat', () {
    testWidgets('renders a value, a unit and its provenance', (tester) async {
      await tester.pumpWidget(host(const Stat(
        label: 'UV peak',
        value: '9.4',
        prov: Prov(
          source: 'open-meteo',
          confidence: Confidence.measured,
          basis: '24 hours observed',
        ),
      )));

      expect(find.text('UV peak'), findsOneWidget);
      expect(find.text('9.4'), findsOneWidget);
      expect(find.byType(Prov), findsOneWidget);
    });

    testWidgets('an unknown value is a dash and never a zero', (tester) async {
      // The lesson already paid for twice: the phone's reader returns 0 for
      // an absent field, and a zero manufactures correlations out of missing
      // data.
      await tester.pumpWidget(host(const Stat(label: 'HRV', value: null)));

      expect(find.text('0'), findsNothing);
      expect(find.text('—'), findsOneWidget);
    });
  });

  group('Empty', () {
    testWidgets('says what will appear here and when', (tester) async {
      await tester.pumpWidget(host(const Empty(
        title: 'No sessions yet',
        body: 'Sessions appear here five minutes before the booked slot.',
      )));

      expect(find.text('No sessions yet'), findsOneWidget);
      expect(
        find.text('Sessions appear here five minutes before the booked slot.'),
        findsOneWidget,
      );
    });

    testWidgets('can offer the action that would fill it', (tester) async {
      var tapped = false;
      await tester.pumpWidget(host(Empty(
        title: 'Nothing to show',
        body: 'Pick a city and we will look up the air each day.',
        actions: [
          EmptyAction(label: 'Choose your city', onPressed: () => tapped = true),
        ],
      )));

      await tester.tap(find.text('Choose your city'));

      expect(tapped, isTrue);
    });

    testWidgets('a result is not an error, and reads as a result',
        (tester) async {
      // "We tested five patterns and none held up" is the screen F12's
      // therapy tab will live in. It takes the same component as an empty
      // list and must not look like a failure.
      await tester.pumpWidget(host(const Empty(
        title: 'No reliable signal yet',
        body: 'We tested five patterns over 60 days and none of them held up. '
            'That is a result, not a gap.',
        tone: EmptyTone.result,
      )));

      expect(find.textContaining('That is a result'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });
  });

  group('Loading', () {
    testWidgets('says what is loading', (tester) async {
      await tester.pumpWidget(host(const Loading('Reading your Vault…')));

      expect(find.text('Reading your Vault…'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });
  });

  group('ErrorState', () {
    testWidgets('retries', (tester) async {
      var retried = false;
      await tester.pumpWidget(host(ErrorState(
        message: 'These patterns could not be worked out just now.',
        onRetry: () => retried = true,
      )));

      await tester.tap(find.text('Try again'));

      expect(retried, isTrue);
    });

    testWidgets('renders without a retry when there is nothing to retry',
        (tester) async {
      await tester.pumpWidget(host(
          const ErrorState(message: 'That upload did not go through.')));

      expect(find.text('Try again'), findsNothing);
      expect(find.textContaining('did not go through'), findsOneWidget);
    });
  });

  group('AppCard', () {
    testWidgets('a toned card is tinted and a plain one is not',
        (tester) async {
      await tester.pumpWidget(host(const Column(children: [
        AppCard(key: Key('plain'), child: T('plain')),
        AppCard(key: Key('teal'), tone: CardTone.teal, child: T('teal')),
        AppCard(key: Key('copper'), tone: CardTone.copper, child: T('copper')),
      ])));

      Color background(String key) => tester
          .widget<Material>(find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(Material),
          ).first)
          .color!;

      expect(background('teal'), isNot(background('plain')));
      expect(background('copper'), isNot(background('plain')));
      expect(background('copper'), isNot(background('teal')));
    });
  });

  group('Section', () {
    testWidgets('has a title and at most one action', (tester) async {
      var acted = false;
      await tester.pumpWidget(host(Section(
        title: 'What your sessions do',
        action: SectionAction(label: 'See all', onPressed: () => acted = true),
        children: const [T('body')],
      )));

      expect(find.text('What your sessions do'), findsOneWidget);
      await tester.tap(find.text('See all'));

      expect(acted, isTrue);
    });
  });

  group('Segmented', () {
    testWidgets('reports the choice', (tester) async {
      int? chosen;
      await tester.pumpWidget(host(Segmented<int>(
        options: const {30: '30 days', 60: '60 days'},
        selected: 30,
        onChanged: (value) => chosen = value,
      )));

      await tester.tap(find.text('60 days'));

      expect(chosen, 60);
    });
  });

  group('ListRow', () {
    testWidgets('renders a title, a trailing value and taps', (tester) async {
      var tapped = false;
      await tester.pumpWidget(host(ListRow(
        title: 'Ferritin',
        subtitle: '3 October 2026',
        trailing: const StatusChip(AppStatus.outOfRange),
        onTap: () => tapped = true,
      )));

      expect(find.text('Ferritin'), findsOneWidget);
      expect(find.text('Out of range'), findsOneWidget);
      await tester.tap(find.text('Ferritin'));

      expect(tapped, isTrue);
    });
  });

  group('Toast', () {
    testWidgets('shows a message over the screen', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(host(Builder(builder: (context) {
        captured = context;
        return const T('screen');
      })));

      showToast(captured, 'Saved to your Vault');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Saved to your Vault'), findsOneWidget);
    });
  });

  group('AppScreen', () {
    testWidgets('refreshes when pulled', (tester) async {
      var refreshed = false;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.build(Brightness.light),
        home: AppScreen(
          title: 'Trends',
          onRefresh: () async => refreshed = true,
          children: const [SizedBox(height: 900, child: T('long'))],
        ),
      ));

      await tester.fling(find.text('long'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();

      expect(refreshed, isTrue);
    });

    testWidgets('constrains its width so a tablet does not get long lines',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.build(Brightness.light),
        home: const AppScreen(title: 'Trends', children: [T('body')]),
      ));
      await tester.pumpAndSettle();

      // Asserted on the list that actually renders the text, not on the
      // ConstrainedBox — `byType(...).first` picks up an ancestor the
      // Scaffold supplies and would pass whatever AppScreen did.
      final list = tester.renderObject<RenderBox>(find.byType(ListView));
      expect(list.size.width, lessThanOrEqualTo(1200));
      expect(tester.view.physicalSize.width, 1600);
    });
  });
}
