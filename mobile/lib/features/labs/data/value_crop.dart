import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Where on a page a value was read from, as fractions of the page.
///
/// This is the check that replaces the verbatim one when the text came from
/// OCR. With a text layer, the number provably appears on the page. With OCR it
/// provably appears in the OCR's *reading* of the page — and `14` misread as
/// `1.4` is a plausible haemoglobin. Asking someone "is 1.4 right?" against
/// their memory is worthless; showing them the piece of their own report it
/// came from is not.
///
/// So the arithmetic here is load-bearing. A crop that is subtly off points at
/// the wrong number and quietly destroys the only safeguard left, which is why
/// it is a plain value object with its own tests rather than maths inlined in a
/// widget.
@immutable
class ValueCrop {
  const ValueCrop({
    required this.centreX,
    required this.centreY,
    required this.widthFactor,
    required this.heightFactor,
  });

  /// Centre of the value, as a fraction of page width and height.
  final double centreX;
  final double centreY;

  /// How much of the page the visible window covers.
  final double widthFactor;
  final double heightFactor;

  /// The same centre in Flutter's `Alignment` range, which runs -1 to 1.
  double get alignmentX => (centreX * 2 - 1).clamp(-1.0, 1.0);
  double get alignmentY => (centreY * 2 - 1).clamp(-1.0, 1.0);

  /// How much wider than the value itself the window should be.
  ///
  /// A bare crop of `7.8` is unreadable out of context — the user needs the row
  /// it sits in to know which test it belongs to, and the printed reference
  /// range beside it is often what makes the number recognisable.
  static const _horizontalContext = 6.0;
  static const _verticalContext = 3.0;

  /// A crop from a stored bounding box, or null when the box cannot be placed.
  ///
  /// Null rather than a default: coordinates are points for a PDF and pixels
  /// for an OCR'd image, so without the page extent there is no way to position
  /// them, and a guessed page size points the crop at the wrong part of the
  /// report. Better to show no picture than the wrong one.
  static ValueCrop? fromBbox(Map<String, dynamic>? bbox) {
    if (bbox == null) return null;

    final x0 = _number(bbox['x0']);
    final x1 = _number(bbox['x1']);
    final top = _number(bbox['top']);
    final bottom = _number(bbox['bottom']);
    final pageWidth = _number(bbox['page_width']);
    final pageHeight = _number(bbox['page_height']);

    if (x0 == null || x1 == null || top == null || bottom == null) return null;
    if (pageWidth == null || pageHeight == null) return null;
    if (pageWidth <= 0 || pageHeight <= 0) return null;
    if (x1 < x0 || bottom < top) return null;

    final width = (x1 - x0) / pageWidth;
    final height = (bottom - top) / pageHeight;

    return ValueCrop(
      centreX: ((x0 + x1) / 2 / pageWidth).clamp(0.0, 1.0),
      centreY: ((top + bottom) / 2 / pageHeight).clamp(0.0, 1.0),
      // Never more than the whole page: a window wider than its child makes
      // Align show the child's edge rather than the value.
      widthFactor: math.min(1.0, math.max(width * _horizontalContext, 0.05)),
      heightFactor: math.min(1.0, math.max(height * _verticalContext, 0.02)),
    );
  }

  /// jsonb returns a whole number as an int, so this is the common case rather
  /// than an edge one.
  static double? _number(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
