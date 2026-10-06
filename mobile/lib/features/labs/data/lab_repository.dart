import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/supabase_config.dart';
import '../models/biomarker_result.dart';
import '../models/lab_upload.dart';
import 'lab_confirmation.dart';
import 'lab_upload_paths.dart';

/// Reading lab reports, and uploading them.
///
/// Reads ride the Supabase client the app already uses — the same reasoning as
/// `ScoreRepository`: no token plumbing on the critical path, and the agent
/// stays invisible to the frontend.
///
/// **Files go straight to Storage and never through our API.** A 20MB
/// photographed panel passing through the gateway would block a worker and
/// couple ingest to compute. The row insert afterwards is what fires the
/// webhook, so the order matters: object first, row second. The reverse would
/// trigger extraction of a file that is not there yet.
///
/// Confirmation is the one write that goes over REST, because it is the only
/// path that may change a result's status — 007 removed the phone's ability to
/// do that directly, since doing so skipped the patient-name check, the
/// collection date, the `origin='server'` projection and the score recompute.
class LabRepository {
  LabRepository({SupabaseClient? client, Dio? http})
      : _client = client,
        _http = http;

  final SupabaseClient? _client;
  final Dio? _http;

  SupabaseClient? get _db {
    if (!SupabaseConfig.configured) return null;
    return _client ?? Supabase.instance.client;
  }

  /// The user's reports, newest first.
  Future<List<LabUpload>> uploads({required String userId}) async {
    final db = _db;
    if (db == null) return const [];
    try {
      final rows = await db
          .from('lab_uploads')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(50);
      return [
        for (final row in rows) LabUpload.fromRow(Map<String, dynamic>.from(row)),
      ];
    } catch (_) {
      // Offline. An empty list is wrong to show as "you have no reports", so
      // the caller distinguishes this by catching its own error state.
      return const [];
    }
  }

  /// The values read off one report, for the confirmation screen.
  Future<List<BiomarkerResult>> resultsFor({
    required String userId,
    required String uploadId,
  }) async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db
        .from('biomarker_results')
        .select()
        .eq('user_id', userId)
        .eq('upload_id', uploadId)
        .order('biomarker_id');
    return [
      for (final row in rows) BiomarkerResult.fromRow(Map<String, dynamic>.from(row)),
    ];
  }

  /// Upload a report's files, then create the row that starts extraction.
  ///
  /// Returns the upload id. Throws if any file is outside what the bucket
  /// accepts, before anything is written — a partial upload is worse than a
  /// refused one, and the sweep would have to clean it up.
  Future<String> upload({
    required String userId,
    required List<LabFile> files,
  }) async {
    final db = _db;
    if (db == null) throw StateError('Supabase is not configured');
    if (files.isEmpty) throw ArgumentError('a report needs at least one file');

    for (final file in files) {
      if (!isAllowedExtension(file.extension)) {
        throw ArgumentError('${file.extension} files cannot be read');
      }
      if (!isWithinSizeCap(file.bytes.length)) {
        throw ArgumentError('${file.name} is larger than 20MB');
      }
    }

    final uploadId = _uuid();
    final prefix = storagePrefixFor(userId: userId, uploadId: uploadId);
    final digests = <String>[];
    final paths = <String>[];

    // Objects first. The row insert fires the webhook, so inserting before the
    // files are in place would start extraction on a document that is not there.
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      final path = objectPathFor(prefix, index, file.extension);
      await db.storage.from(labReportBucket).uploadBinary(path, file.bytes);
      digests.add(fileDigest(file.bytes));
      paths.add(path);
    }

    await db.from('lab_uploads').insert({
      'id': uploadId,
      'user_id': userId,
      'storage_provider': 'supabase',
      'storage_prefix': prefix,
      'content_sha256': reportDigest(digests),
      'status': 'uploaded',
    });

    await db.from('lab_upload_files').insert([
      for (var index = 0; index < files.length; index++)
        {
          'upload_id': uploadId,
          'storage_path': paths[index],
          'content_sha256': digests[index],
          'page_index': index,
          'kind': files[index].extension.toLowerCase() == 'pdf' ? 'pdf' : 'image',
          'byte_size': files[index].bytes.length,
        },
    ]);

    return uploadId;
  }

  /// Confirm what we read. The only path that can make a result count.
  Future<void> confirm({
    required String uploadId,
    required ConfirmationDraft draft,
  }) async {
    if (!draft.canSubmit) {
      // The screen should already have said why. Reaching the endpoint with a
      // known-bad body produces a 422 the user cannot interpret.
      throw ArgumentError(draft.blockers.join(' '));
    }
    final http = _http;
    if (http == null) throw StateError('no API client');
    await http.post('/api/v1/labs/uploads/$uploadId/confirm', data: draft.toRequest());
  }

  // A timestamp would collide across devices, and the id becomes a storage
  // folder name that two users must never share.
  String _uuid() => const Uuid().v4();
}

/// One file the user picked, already in memory.
class LabFile {
  const LabFile({required this.name, required this.extension, required this.bytes});

  final String name;
  final String extension;
  final Uint8List bytes;
}
