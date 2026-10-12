import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/genetics/widgets/genetics_consent.dart';

/// What somebody is told before they upload a genome.
///
/// These are content tests, which is unusual and is the point. The failure
/// this guards against is not a crash — it is somebody tightening the copy
/// six months from now and dropping the sentence about APOE or the one about
/// relatives, which would leave a consent that is shorter, reads better and
/// no longer says the thing a person needed to hear.

void main() {
  group('the consent says the four things it has to', () {
    test('what we keep, and that it is a short list', () {
      expect(geneticsWhatWeKeep.toLowerCase(), contains('four'));
      expect(geneticsWhatWeKeep.toLowerCase(), contains('wellness'));
    });

    test('that the rest is discarded and never stored', () {
      final text = geneticsWhatWeDiscard.toLowerCase();

      expect(text, contains('discarded'));
      expect(text, contains('never'));
    });

    test('that APOE specifically is never read', () {
      // Named rather than implied. Somebody worried about Alzheimer's is
      // exactly the person who needs to know we never read it, rather than
      // being left to wonder whether we read it and chose silence.
      expect(geneticsWhatWeDiscard, contains('APOE'));
      expect(geneticsWhatWeDiscard.toLowerCase(), contains('alzheimer'));
    });

    test('that a variant is useless without a blood result', () {
      // Otherwise somebody uploads a genome, sees nothing change, and
      // concludes the feature is broken.
      expect(geneticsHowItIsUsed.toLowerCase(), contains('blood result'));
    });

    test('that a genome is partly about relatives who did not agree', () {
      // The one almost no consumer product says. It costs uploads, it is
      // true, and a person cannot work it out from the other three.
      final text = geneticsAboutRelatives.toLowerCase();

      expect(
        text,
        anyOf(contains('siblings'), contains('children'), contains('parents')),
      );
      expect(text, contains('not agreed'));
    });

    test('what happens to the file, and that it can be taken back', () {
      final text = geneticsWhatHappensToTheFile.toLowerCase();

      expect(text, contains('deleted'));
      expect(text, contains('without closing your account'));
    });

    test('and how to deal with the zip 23andMe actually gives you', () {
      expect(geneticsUnzipFirst.toLowerCase(), contains('unzip'));
      expect(geneticsUnzipFirst.toLowerCase(), contains('.txt'));
    });
  });

  group('the sheet', () {
    /// The answer is captured into a variable rather than asserted inside
    /// the callback: an `expect` in a callback that never fires is a test
    /// that passes having checked nothing, and `null` here means the sheet
    /// never resolved at all — which must not read as a decision either way.
    late bool? answer;

    Future<void> open(WidgetTester tester) async {
      answer = null;
      // Taller than the 800x600 default, which puts the sheet's buttons off
      // the bottom of the render tree. The sheet is scroll-controlled so a
      // real phone scrolls to them; the test surface does not scroll itself.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  answer = await confirmGeneticsUpload(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows every fact before anything is picked', (tester) async {
      await open(tester);

      expect(find.byKey(const Key('genetics-consent-title')), findsOneWidget);
      expect(find.textContaining('APOE'), findsOneWidget);
      expect(find.textContaining('siblings'), findsOneWidget);
      expect(find.textContaining('blood result'), findsOneWidget);
      // Still open: nothing has been decided yet.
      expect(answer, isNull);
    });

    testWidgets('declining is a no', (tester) async {
      await open(tester);

      await tester.tap(find.byKey(const Key('genetics-consent-cancel')));
      await tester.pumpAndSettle();

      expect(answer, isFalse);
    });

    testWidgets('agreeing is a yes', (tester) async {
      await open(tester);

      await tester.tap(find.byKey(const Key('genetics-consent-continue')));
      await tester.pumpAndSettle();

      expect(answer, isTrue);
    });

    testWidgets('a sheet dismissed without choosing is a no', (tester) async {
      // Swiped away, or the back button. Neither is agreement, and
      // `confirmGeneticsUpload` turns the null into false rather than
      // letting a caller treat "no answer" as one.
      await open(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(answer, isFalse);
    });
  });

  group('the deletion dialog', () {
    testWidgets('warns that the variants go too, not just the file',
        (tester) async {
      // Somebody deleting "the file" may not expect to lose what was read
      // out of it, and quietly keeping the genotypes would be the wrong way
      // to resolve that.
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => confirmGeneticsDeletion(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('genetics-delete-dialog')), findsOneWidget);
      expect(find.textContaining('variants we read out of it'), findsOneWidget);
      expect(find.textContaining('account'), findsOneWidget);
    });
  });
}
