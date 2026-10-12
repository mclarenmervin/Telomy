import 'package:flutter/foundation.dart';

/// An uploaded genetics export, as the server has read it.
///
/// The two counts are the interesting part and the reason this model exists
/// rather than a bare status string. "We read 612,431 rows and kept 3" is the
/// one sentence that tells somebody what actually happened to their genome,
/// and it is the only thing we will say about the rows we did not keep —
/// there is no field here, and no column in the database, in which a refused
/// variant could be named.
@immutable
class GeneticUpload {
  const GeneticUpload({
    required this.id,
    required this.status,
    required this.sourceFormat,
    required this.rowsRead,
    required this.rowsKept,
    required this.failureReason,
    required this.importedAt,
    required this.purgedAt,
    required this.createdAt,
  });

  final String id;
  final String status;

  /// `23andme` or `vcf`, once the parser has recognised it. For support
  /// rather than for logic.
  final String? sourceFormat;

  final int? rowsRead;
  final int? rowsKept;

  /// Why it could not be read, in words a person can act on. Never names a
  /// locus: the file we could not read is still the file we are refusing to
  /// describe.
  final String? failureReason;

  final DateTime? importedAt;

  /// When the raw file was removed. Unlike a lab report, which is provenance
  /// for a number we show forever, an export is provenance for a parse and
  /// does not outlive it by much.
  final DateTime? purgedAt;

  final DateTime? createdAt;

  /// The server is still working on it. A screen showing this has to refresh
  /// itself, or it says "Reading your file..." forever — which is exactly how
  /// the lab tile behaved on the first real device.
  bool get isInFlight => status == 'uploaded';
  bool get isImported => status == 'imported';

  /// Not a format we read. Terminal, and a different thing from [hasFailed]:
  /// there is nothing to retry, and the user needs to upload a different file
  /// rather than wait.
  bool get isUnreadable => status == 'unreadable';
  bool get hasFailed => status == 'failed';
  bool get isPurged => status == 'purged';

  /// The file is gone and the variants remain. Worth saying plainly rather
  /// than leaving somebody to assume we are still holding their genome.
  bool get fileIsGone => purgedAt != null || status == 'purged';

  static DateTime? _date(Object? value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString())?.toLocal();
  }

  static int? _count(Object? value) => (value as num?)?.toInt();

  static GeneticUpload fromRow(Map<String, dynamic> row) => GeneticUpload(
        id: row['id']?.toString() ?? '',
        status: row['status']?.toString() ?? 'uploaded',
        sourceFormat: row['source_format']?.toString(),
        rowsRead: _count(row['rows_read']),
        rowsKept: _count(row['rows_kept']),
        failureReason: row['failure_reason']?.toString(),
        importedAt: _date(row['imported_at']),
        purgedAt: _date(row['purged_at']),
        createdAt: _date(row['created_at']),
      );
}

/// One wellness variant we kept, as the user may see it.
///
/// There is no screen that lists these on their own and there is deliberately
/// no agent tool that returns them, because a variant may never originate an
/// insight — it appears beside a measured marker or not at all. This model
/// exists so an import can say what it kept, which is a different thing from
/// interpreting it: a genotype with no explanation beside it is a fact about
/// the person's body, and the explanation is what waits for a signature.
@immutable
class StoredVariant {
  const StoredVariant({required this.rsid, required this.genotype});

  final String rsid;
  final String genotype;

  static StoredVariant fromRow(Map<String, dynamic> row) => StoredVariant(
        rsid: row['rsid']?.toString() ?? '',
        genotype: row['genotype']?.toString() ?? '',
      );
}

/// How an import went, in the words the screen uses.
String geneticImportSummary(GeneticUpload upload) {
  if (upload.isInFlight) return 'Reading your file…';
  if (upload.isUnreadable) {
    return upload.failureReason ??
        'This is not a 23andMe export or a VCF, so we could not read it.';
  }
  if (upload.hasFailed) {
    return upload.failureReason ?? 'Something went wrong on our side.';
  }
  final read = upload.rowsRead;
  final kept = upload.rowsKept;
  if (read == null || kept == null) return 'Imported.';
  return 'We read ${_thousands(read)} rows and kept $kept. '
      'Everything else was discarded as it was read.';
}

String _thousands(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
