import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/features/genetics/data/genetic_upload_paths.dart';
import 'package:telomy/features/genetics/models/genetic_upload.dart';

/// Uploading a genome, and what the phone is and is not allowed to do with it.
///
/// The phone's job here is narrow on purpose: put the whole file in the right
/// bucket under the right path and insert one row. It does not filter, it
/// does not parse, and it does not decide which variants exist — all of that
/// is the worker's, inside `genetics.import_raw`, where it cannot be changed
/// without a deploy and cannot be skipped by a client that forgot.

void main() {
  group('where the file goes', () {
    test('the first path segment is the owner', () {
      // The policies on storage.objects compare
      // (storage.foldername(name))[1] against auth.uid(). Isolation is the
      // storage layer's, and only if the path is built this way.
      final path = geneticObjectPathFor(
        userId: 'abc-123',
        uploadId: 'upload-9',
        year: 2026,
      );

      expect(path, 'abc-123/2026/upload-9/raw.txt');
      expect(path.split('/').first, 'abc-123');
    });

    test('it is its own bucket and not the lab one', () {
      // A lab report describes a person today; a genome describes them for
      // life and partly describes relatives who never consented.
      expect(geneticsBucket, 'genetics');
      expect(geneticsBucket, isNot('lab-reports'));
    });

    test('an export is one file rather than numbered pages', () {
      expect(
        geneticObjectPathFor(userId: 'u', uploadId: 'x', year: 2026),
        endsWith('/raw.txt'),
      );
    });
  });

  group('what we will accept', () {
    test('a 23andMe text export and a VCF', () {
      expect(isAllowedGeneticExtension('txt'), isTrue);
      expect(isAllowedGeneticExtension('vcf'), isTrue);
      expect(isAllowedGeneticExtension('TXT'), isTrue);
    });

    test('not a PDF, and not an image of one', () {
      expect(isAllowedGeneticExtension('pdf'), isFalse);
      expect(isAllowedGeneticExtension('jpg'), isFalse);
    });

    test('an archive is recognised as one so the advice can be useful', () {
      // 23andMe hands you a .zip. "zip files cannot be read" invites
      // somebody to give up; "unzip it first" is the same refusal with the
      // answer attached.
      expect(looksLikeAnArchive('zip'), isTrue);
      expect(looksLikeAnArchive('gz'), isTrue);
      expect(looksLikeAnArchive('txt'), isFalse);
    });

    test('the size cap matches the bucket', () {
      expect(maxGeneticUploadBytes, 30 * 1024 * 1024);
      expect(isWithinGeneticSizeCap(25 * 1024 * 1024), isTrue);
      expect(isWithinGeneticSizeCap(31 * 1024 * 1024), isFalse);
    });

    test('the content type is one the bucket allows', () {
      // Supabase infers application/octet-stream for an unfamiliar
      // extension like .vcf, which the bucket then refuses.
      expect(geneticsContentType, 'text/plain');
    });
  });

  group('the digest', () {
    test('the same export twice is the same digest', () {
      final bytes = Uint8List.fromList('rs1801133\t1\t11856378\tTT\n'.codeUnits);

      expect(geneticFileDigest(bytes), geneticFileDigest(bytes));
    });

    test('a different export is a different digest', () {
      final a = Uint8List.fromList('rs1801133\t1\t11856378\tTT\n'.codeUnits);
      final b = Uint8List.fromList('rs1801133\t1\t11856378\tCT\n'.codeUnits);

      expect(geneticFileDigest(a), isNot(geneticFileDigest(b)));
    });
  });

  group('what the screen says happened', () {
    GeneticUpload upload(Map<String, dynamic> overrides) =>
        GeneticUpload.fromRow({
          'id': 'u1',
          'status': 'imported',
          'source_format': '23andme',
          'rows_read': 612431,
          'rows_kept': 3,
          ...overrides,
        });

    test('the counts are the whole story and carry no identities', () {
      final summary = geneticImportSummary(upload({}));

      expect(summary, contains('612,431'));
      expect(summary, contains('kept 3'));
      expect(summary, contains('discarded'));
    });

    test('an unreadable file is terminal and says what to do', () {
      final row = upload({
        'status': 'unreadable',
        'failure_reason': 'this is not a 23andMe raw export or a VCF',
        'rows_read': null,
        'rows_kept': null,
      });

      expect(row.isUnreadable, isTrue);
      expect(row.hasFailed, isFalse);
      expect(geneticImportSummary(row), contains('not a 23andMe'));
    });

    test('a failure on our side is a different thing from an unreadable file',
        () {
      // One is "upload a different file", the other is "wait". Telling a
      // person to wait for something that will never finish is the worse of
      // the two.
      final row = upload({'status': 'failed', 'rows_read': null, 'rows_kept': null});

      expect(row.hasFailed, isTrue);
      expect(row.isUnreadable, isFalse);
    });

    test('an import still running says so, because a screen has to refresh',
        () {
      final row = upload({'status': 'uploaded', 'rows_read': null, 'rows_kept': null});

      expect(row.isInFlight, isTrue);
      expect(geneticImportSummary(row), contains('Reading'));
    });

    test('a purged file is said plainly rather than left to assumption', () {
      // Otherwise somebody is left believing we still hold their genome.
      final row = upload({
        'status': 'purged',
        'purged_at': '2026-10-12T04:00:00Z',
      });

      expect(row.fileIsGone, isTrue);
    });

    test('an import with no counts yet does not print nulls', () {
      final row = upload({'rows_read': null, 'rows_kept': null});

      expect(geneticImportSummary(row), isNot(contains('null')));
    });
  });

  group('a stored variant', () {
    test('is labelled well enough for a person to read', () {
      // On the device these rendered as `rs855791 · AA`, which is accurate
      // and tells somebody nothing. The gene and trait are labels, not
      // claims.
      final variant = StoredVariant.fromRow({
        'rsid': 'rs855791',
        'gene': 'TMPRSS6',
        'trait': 'iron regulation',
        'genotype': 'AA',
        'note': null,
        'note_reviewed': false,
      });

      expect(variant.label, 'TMPRSS6 · iron regulation');
      expect(variant.genotype, 'AA');
    });

    test('says what it is and not what it means', () {
      final variant = StoredVariant.fromRow({
        'rsid': 'rs855791',
        'gene': 'TMPRSS6',
        'trait': 'iron regulation',
        'genotype': 'AA',
        'note': null,
        'note_reviewed': false,
      });

      expect(variant.note, isNull);
      expect(variant.noteReviewed, isFalse);
    });

    test('carries a signed note when there is one', () {
      final variant = StoredVariant.fromRow({
        'rsid': 'rs855791',
        'gene': 'TMPRSS6',
        'trait': 'iron regulation',
        'genotype': 'AA',
        'note': 'Associated with slightly lower average iron indices.',
        'note_reviewed': true,
      });

      expect(variant.noteReviewed, isTrue);
      expect(variant.note, contains('iron indices'));
    });

    test('a gene with no trait still labels as something', () {
      final variant = StoredVariant.fromRow({
        'rsid': 'rs1',
        'gene': 'GENE',
        'trait': '',
        'genotype': 'AA',
      });

      expect(variant.label, 'GENE');
    });
  });
}
