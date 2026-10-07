import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/labs/data/capture_advice.dart';

/// Catching an unusable photo before it is uploaded.
///
/// The alternative is the user waiting for an upload, then an extraction, then
/// a failure that says "we could not read the text" — by which time they have
/// put the report away. Every check here is something we can know from the file
/// itself, and every message says what to do rather than what went wrong.
///
/// This is the part of capture-time correction that does not need a native
/// scanner. The scanner is the bigger lever and needs a device build.

void main() {
  group('file type', () {
    test('a PDF is fine', () {
      expect(adviseOnCapture(extension: 'pdf', byteSize: 200000), isEmpty);
    });

    test('a JPEG of a full page is fine', () {
      expect(
        adviseOnCapture(extension: 'jpg', byteSize: 900000, width: 2400, height: 3200),
        isEmpty,
      );
    });

    test('HEIC is refused with the reason', () {
      // iPhones shoot HEIC by default and the bucket rejects it, so the user
      // must be told here rather than after a failed upload.
      final advice = adviseOnCapture(extension: 'heic', byteSize: 900000);

      expect(advice, isNotEmpty);
      expect(advice.first.toLowerCase(), contains('jpeg'));
    });

    test('an unsupported type is refused', () {
      expect(adviseOnCapture(extension: 'docx', byteSize: 50000), isNotEmpty);
    });
  });

  group('size', () {
    test('a file over the bucket cap is refused before it is uploaded', () {
      // Refused here rather than after spending the user's data allowance on
      // an upload the bucket will reject anyway.
      final advice = adviseOnCapture(extension: 'jpg', byteSize: 25 * 1024 * 1024);

      expect(advice.join(' ').toLowerCase(), contains('20mb'));
    });

    test('an empty file is refused', () {
      expect(adviseOnCapture(extension: 'jpg', byteSize: 0), isNotEmpty);
    });
  });

  group('resolution', () {
    test('a photo too small to hold readable 8pt type is refused', () {
      // Lab reports are typically 8pt. A 640x480 snap of a full page cannot
      // resolve it at any OCR quality, so uploading it wastes everyone's time.
      final advice = adviseOnCapture(
        extension: 'jpg', byteSize: 90000, width: 640, height: 480,
      );

      expect(advice, isNotEmpty);
      expect(advice.first.toLowerCase(), contains('closer'));
    });

    test('a full-page phone photo is accepted', () {
      expect(
        adviseOnCapture(extension: 'jpg', byteSize: 1200000, width: 3024, height: 4032),
        isEmpty,
      );
    });

    test('an extreme aspect ratio suggests a partial capture', () {
      // A very wide, short image is usually one row photographed rather than
      // the page, which loses the header, the dates and the patient name.
      final advice = adviseOnCapture(
        extension: 'jpg', byteSize: 400000, width: 3000, height: 400,
      );

      expect(advice.join(' ').toLowerCase(), contains('whole page'));
    });

    test('unknown dimensions do not block the upload', () {
      // Decoding can fail for reasons that say nothing about the photo. Better
      // to try the upload than to refuse a perfectly good report.
      expect(adviseOnCapture(extension: 'jpg', byteSize: 900000), isEmpty);
    });

    test('a PDF is not judged on resolution', () {
      expect(
        adviseOnCapture(extension: 'pdf', byteSize: 20000, width: 10, height: 10),
        isEmpty,
      );
    });
  });

  group('what the advice reads like', () {
    test('every message tells the user what to do', () {
      final cases = [
        adviseOnCapture(extension: 'heic', byteSize: 900000),
        adviseOnCapture(extension: 'jpg', byteSize: 25 * 1024 * 1024),
        adviseOnCapture(
            extension: 'jpg', byteSize: 90000, width: 640, height: 480),
      ];

      for (final advice in cases) {
        expect(advice, isNotEmpty);
        // An instruction, not a diagnosis.
        expect(
          advice.first.contains('Please') ||
              advice.first.contains('Try') ||
              advice.first.contains('Take'),
          isTrue,
          reason: 'not actionable: ${advice.first}',
        );
      }
    });
  });

  group('how to take a usable photo', () {
    test('the tips are short and specific', () {
      expect(captureTips, isNotEmpty);
      for (final tip in captureTips) {
        expect(tip.length, lessThan(70));
      }
    });
  });
}
