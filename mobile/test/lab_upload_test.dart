import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/labs/data/lab_upload_paths.dart';

/// Where an uploaded report goes, and what makes two uploads the same report.
///
/// The first path segment is not a naming convention. The policies on
/// `storage.objects` key on it, so getting it wrong is the difference between
/// isolation enforced by the storage layer and isolation enforced by our code
/// remembering to filter.

const user = '00000000-0000-0000-0000-00000000000a';
const uploadId = '11111111-1111-4111-8111-111111111111';

void main() {
  group('paths', () {
    test('the owner is the first segment', () {
      final prefix = storagePrefixFor(userId: user, uploadId: uploadId, year: 2026);

      expect(prefix.split('/').first, user);
      expect(prefix, '$user/2026/$uploadId/');
    });

    test('files are numbered by page', () {
      final prefix = storagePrefixFor(userId: user, uploadId: uploadId, year: 2026);

      expect(objectPathFor(prefix, 0, 'pdf'), '$user/2026/$uploadId/0.pdf');
      expect(objectPathFor(prefix, 2, 'jpg'), '$user/2026/$uploadId/2.jpg');
    });

    test('an uppercase extension is normalised', () {
      final prefix = storagePrefixFor(userId: user, uploadId: uploadId, year: 2026);

      expect(objectPathFor(prefix, 0, 'PDF'), endsWith('0.pdf'));
    });

    test('a jpeg extension is stored as jpg so paths are predictable', () {
      final prefix = storagePrefixFor(userId: user, uploadId: uploadId, year: 2026);

      expect(objectPathFor(prefix, 0, 'jpeg'), endsWith('0.jpg'));
    });
  });

  group('what the bucket accepts', () {
    test('pdf and photographs are allowed', () {
      expect(isAllowedExtension('pdf'), isTrue);
      expect(isAllowedExtension('jpg'), isTrue);
      expect(isAllowedExtension('png'), isTrue);
    });

    test('heic is refused on this side', () {
      // iPhones shoot HEIC by default and the bucket rejects it. Exporting JPEG
      // at capture is one line here against a server dependency and a class of
      // failures there, so the app must not offer it.
      expect(isAllowedExtension('heic'), isFalse);
    });

    test('anything else is refused', () {
      expect(isAllowedExtension('exe'), isFalse);
      expect(isAllowedExtension('zip'), isFalse);
      expect(isAllowedExtension(''), isFalse);
    });

    test('the size cap matches the bucket', () {
      expect(maxUploadBytes, 20 * 1024 * 1024);
    });

    test('a file at the cap is accepted and one over it is not', () {
      expect(isWithinSizeCap(maxUploadBytes), isTrue);
      expect(isWithinSizeCap(maxUploadBytes + 1), isFalse);
    });
  });

  group('the report digest', () {
    test('it is stable for the same files in the same order', () {
      expect(reportDigest(['a', 'b']), reportDigest(['a', 'b']));
    });

    test('reordering the pages is a different report', () {
      // Page order is part of the document: provenance says "page 2", and two
      // orderings are two different readings of the same photographs.
      expect(reportDigest(['a', 'b']), isNot(reportDigest(['b', 'a'])));
    });

    test('a different page makes a different report', () {
      expect(reportDigest(['a', 'b']), isNot(reportDigest(['a', 'c'])));
    });

    test('it is a hex sha256', () {
      expect(reportDigest(['a']), matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('a single-file report digests its one file', () {
      expect(reportDigest(['a']), isNot(reportDigest([])));
    });
  });

  group('file digests', () {
    test('the same bytes give the same digest', () {
      final bytes = utf8.encode('%PDF-1.7 a report');

      expect(fileDigest(bytes), fileDigest(bytes));
    });

    test('different bytes give different digests', () {
      expect(
        fileDigest(utf8.encode('one')),
        isNot(fileDigest(utf8.encode('two'))),
      );
    });

    test('it is a hex sha256', () {
      expect(fileDigest(utf8.encode('x')), matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });
}
