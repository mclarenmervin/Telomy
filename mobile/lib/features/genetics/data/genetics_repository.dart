import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/supabase_config.dart';
import '../models/genetic_upload.dart';
import 'genetic_upload_paths.dart';

/// Uploading a genetics export, and reading back what survived it.
///
/// **The file goes straight to Storage and never through our API**, the same
/// rule a lab report follows and for the same reason: tens of megabytes
/// passing through the gateway would block a worker and couple ingest to
/// compute. The row insert afterwards is what fires the webhook, so the
/// order matters — object first, row second. The reverse would start an
/// import of a file that is not there yet.
///
/// **Nothing here filters anything.** The whole file is uploaded and the
/// allowlist is applied by the worker, inside `genetics.import_raw`, between
/// parsing and returning. Doing it on the phone would put the decision about
/// which variants exist in client code that anybody can read and that we
/// cannot change without a release — and it would mean trusting the client
/// to have done it.
class GeneticsRepository {
  GeneticsRepository({SupabaseClient? client}) : _client = client;

  final SupabaseClient? _client;

  SupabaseClient? get _db {
    if (!SupabaseConfig.configured) return null;
    return _client ?? Supabase.instance.client;
  }

  /// This person's imports, newest first.
  Future<List<GeneticUpload>> uploads({required String userId}) async {
    final db = _db;
    if (db == null) return const [];
    try {
      final rows = await db
          .from('genetic_uploads')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(20);
      return [
        for (final row in rows)
          GeneticUpload.fromRow(Map<String, dynamic>.from(row)),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// The wellness variants we kept.
  ///
  /// Shown on the genetics screen so somebody can see what we hold about
  /// them, and nowhere else. There is no agent tool for this and no loader
  /// method that returns it without a lab result beside it — a person
  /// looking at their own record is a different thing from a model being
  /// handed genotypes to reason about.
  Future<List<StoredVariant>> variants({required String userId}) async {
    final db = _db;
    if (db == null) return const [];
    try {
      final rows = await db
          .from('genetic_variants')
          .select('rsid,genotype')
          .eq('user_id', userId)
          .order('rsid');
      return [
        for (final row in rows)
          StoredVariant.fromRow(Map<String, dynamic>.from(row)),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Upload an export, then create the row that starts the import.
  ///
  /// Throws before anything is written if the file is outside what the
  /// bucket accepts: a partial upload is worse than a refused one, and the
  /// sweep would have to clean it up.
  Future<String> upload({
    required String userId,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final db = _db;
    if (db == null) throw StateError('Supabase is not configured');

    final extension = _extensionOf(fileName);
    if (looksLikeAnArchive(extension)) {
      throw ArgumentError(
        'Unzip the download first and upload the .txt file inside it.',
      );
    }
    if (!isAllowedGeneticExtension(extension)) {
      throw ArgumentError(
        'We can read a 23andMe .txt export or a .vcf file. '
        'This is a .$extension.',
      );
    }
    if (bytes.isEmpty) {
      throw ArgumentError('That file is empty.');
    }
    if (!isWithinGeneticSizeCap(bytes.length)) {
      throw ArgumentError('That file is larger than 30MB.');
    }

    final uploadId = const Uuid().v4();
    final path = geneticObjectPathFor(userId: userId, uploadId: uploadId);

    // Object first. The row insert fires the webhook.
    await db.storage.from(geneticsBucket).uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(contentType: geneticsContentType),
        );

    await db.from('genetic_uploads').insert({
      'id': uploadId,
      'user_id': userId,
      'storage_provider': 'supabase',
      'storage_path': path,
      'content_sha256': geneticFileDigest(bytes),
      'status': 'uploaded',
    });

    return uploadId;
  }

  /// Remove everything we hold from a person's genome.
  ///
  /// The variants, the upload rows and the objects. This is the one deletion
  /// in the product that is more than a convenience: somebody who regrets
  /// uploading their genome must be able to take it back without closing
  /// their account, and 018 and 019 grant exactly these deletes for that
  /// reason.
  Future<void> deleteEverything({required String userId}) async {
    final db = _db;
    if (db == null) return;

    final rows = await db
        .from('genetic_uploads')
        .select('storage_path')
        .eq('user_id', userId);
    final paths = [
      for (final row in rows)
        if (row['storage_path'] != null) row['storage_path'].toString(),
    ];

    // Objects first, then rows. The reverse would lose the paths and leave
    // the files behind with nothing pointing at them — unreachable rather
    // than deleted, which is the distinction 009 exists to hold.
    if (paths.isNotEmpty) {
      await db.storage.from(geneticsBucket).remove(paths);
    }
    await db.from('genetic_variants').delete().eq('user_id', userId);
    await db.from('genetic_uploads').delete().eq('user_id', userId);
  }

  String _extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toLowerCase();
  }
}
