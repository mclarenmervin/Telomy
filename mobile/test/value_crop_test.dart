import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/labs/data/value_crop.dart';

/// Turning a stored bounding box into a crop of the user's own report.
///
/// This is the check that replaces the verbatim one when the text came from
/// OCR. With a text layer, the number provably appears on the page. With OCR it
/// provably appears in the OCR's *reading* of the page — and `14` misread as
/// `1.4` is a plausible haemoglobin. Asking "is 1.4 right?" against someone's
/// memory is worthless; showing them the piece of their own photograph it came
/// from is not.
///
/// So the arithmetic here is load-bearing. A crop that is subtly off points at
/// the wrong number and quietly destroys the only safeguard left.

Map<String, dynamic> box({
  double x0 = 250,
  double x1 = 270,
  double top = 100,
  double bottom = 110,
  double pageWidth = 500,
  double pageHeight = 1000,
}) {
  return {
    'x0': x0,
    'x1': x1,
    'top': top,
    'bottom': bottom,
    'page_width': pageWidth,
    'page_height': pageHeight,
  };
}

void main() {
  group('reading the box', () {
    test('a well-formed box is usable', () {
      expect(ValueCrop.fromBbox(box()), isNotNull);
    });

    test('a box with no page size is refused', () {
      // Coordinates are points for a PDF and pixels for an image, so without
      // the extent there is no way to place them. Guessing a page size would
      // point the crop at the wrong part of the report.
      final without = box()..remove('page_width');

      expect(ValueCrop.fromBbox(without), isNull);
    });

    test('a zero-sized page is refused rather than divided by', () {
      expect(ValueCrop.fromBbox(box(pageWidth: 0)), isNull);
      expect(ValueCrop.fromBbox(box(pageHeight: 0)), isNull);
    });

    test('a null box is refused', () {
      expect(ValueCrop.fromBbox(null), isNull);
    });

    test('an inverted box is refused', () {
      expect(ValueCrop.fromBbox(box(x0: 300, x1: 250)), isNull);
    });
  });

  group('the fractions it computes', () {
    test('a box in the middle of the page lands in the middle', () {
      final crop = ValueCrop.fromBbox(box(
        x0: 200, x1: 300, top: 400, bottom: 600,
        pageWidth: 500, pageHeight: 1000,
      ))!;

      // Centre of the box is (250, 500) on a 500x1000 page: dead centre.
      expect(crop.centreX, closeTo(0.5, 0.001));
      expect(crop.centreY, closeTo(0.5, 0.001));
    });

    test('a box at the top left lands at the top left', () {
      final crop = ValueCrop.fromBbox(box(
        x0: 0, x1: 50, top: 0, bottom: 100,
        pageWidth: 500, pageHeight: 1000,
      ))!;

      expect(crop.centreX, closeTo(0.05, 0.001));
      expect(crop.centreY, closeTo(0.05, 0.001));
    });

    test('alignment is expressed in Flutter\'s -1 to 1 range', () {
      final centre = ValueCrop.fromBbox(box(
        x0: 200, x1: 300, top: 400, bottom: 600,
      ))!;

      expect(centre.alignmentX, closeTo(0, 0.001));
      expect(centre.alignmentY, closeTo(0, 0.001));
    });

    test('a box at the far edges clamps into range', () {
      final crop = ValueCrop.fromBbox(box(
        x0: 480, x1: 500, top: 980, bottom: 1000,
        pageWidth: 500, pageHeight: 1000,
      ))!;

      expect(crop.alignmentX, lessThanOrEqualTo(1));
      expect(crop.alignmentY, lessThanOrEqualTo(1));
    });
  });

  group('the window it shows', () {
    test('it is wider than the value itself', () {
      // A bare crop of "7.8" is unreadable out of context: the user needs to
      // see the row it sits in to know which test it belongs to.
      final crop = ValueCrop.fromBbox(box(x0: 250, x1: 270))!;

      expect(crop.widthFactor, greaterThan((270 - 250) / 500));
    });

    test('the window never exceeds the page', () {
      final crop = ValueCrop.fromBbox(box(x0: 0, x1: 500, pageWidth: 500))!;

      expect(crop.widthFactor, lessThanOrEqualTo(1));
      expect(crop.heightFactor, lessThanOrEqualTo(1));
    });

    test('a tall value still gets a usable window', () {
      final crop = ValueCrop.fromBbox(box(top: 0, bottom: 1000))!;

      expect(crop.heightFactor, greaterThan(0));
      expect(crop.heightFactor, lessThanOrEqualTo(1));
    });
  });

  group('integer coordinates', () {
    test('a box stored with ints rather than doubles still works', () {
      // jsonb round-trips a whole number as an int, so this is the common case
      // rather than an edge one.
      final crop = ValueCrop.fromBbox({
        'x0': 250, 'x1': 270, 'top': 100, 'bottom': 110,
        'page_width': 500, 'page_height': 1000,
      });

      expect(crop, isNotNull);
    });
  });
}
