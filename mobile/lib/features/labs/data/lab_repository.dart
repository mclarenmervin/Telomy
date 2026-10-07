import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/supabase_config.dart';
import '../models/biomarker_result.dart';
import '../models/lab_escalation.dart';
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

  /// Everything the confirmation screen needs, in one call.
  ///
  /// Over REST rather than from the tables, because two of the three things it
  /// returns only exist on the server: the grade, which is `ungraded` until a
  /// clinician signs the catalog off, and a short-lived signed URL per page,
  /// which is what lets the screen show each value in context.
  Future<LabReview> review({required String uploadId}) async {
    final http = _http;
    if (http == null) throw StateError('no API client');

    final response = await http.get('/api/v1/labs/uploads/$uploadId');
    final body = Map<String, dynamic>.from(response.data as Map);

    return LabReview(
      upload: LabUpload.fromRow(Map<String, dynamic>.from(body['upload'] as Map)),
      results: [
        for (final row in (body['results'] as List? ?? const []))
          BiomarkerResult.fromRow(Map<String, dynamic>.from(row as Map)),
      ],
      // Images only. A PDF page has no bitmap to crop -- Flutter cannot decode
      // one, and trying leaves an empty bordered box where a picture should be,
      // which is worse than showing nothing. The crop matters most for
      // photographs and scans anyway, since those are the ones read by OCR.
      pageUrls: {
        for (final page in (body['pages'] as List? ?? const []))
          if ((page as Map)['url'] != null && page['kind'] == 'image')
            (page['page_index'] as num).toInt(): page['url'].toString(),
      },
    );
  }

  /// Critical findings the user has not yet seen.
  ///
  /// Read straight from the table rather than over REST: this must work on a
  /// cold start with a flaky connection, and it is the one thing on the screen
  /// that genuinely cannot wait.
  Future<List<LabEscalation>> outstandingEscalations({required String userId}) async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db
        .from('lab_escalations')
        .select()
        .eq('user_id', userId)
        .isFilter('acknowledged_at', null)
        .order('created_at', ascending: false);
    return [
      for (final row in rows) LabEscalation.fromRow(Map<String, dynamic>.from(row)),
    ];
  }

  /// Mark a finding seen. The only column the phone is allowed to write here --
  /// 008 grants UPDATE on acknowledged_at alone, so it cannot rewrite the
  /// finding itself.
  Future<void> acknowledgeEscalation(String id) async {
    final db = _db;
    if (db == null) return;
    await db
        .from('lab_escalations')
        .update({'acknowledged_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', id);
  }

  /// Every value the user has confirmed, newest sample first.
  ///
  /// Only `confirmed` and `corrected`. An `extracted` row has not been checked
  /// by anyone yet and must not appear beside values that have -- that is the
  /// whole point of the confirmation step.
  Future<List<BiomarkerResult>> confirmedResults({required String userId}) async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db
        .from('biomarker_results')
        .select()
        .eq('user_id', userId)
        .inFilter('status', ['confirmed', 'corrected'])
        .order('collected_at', ascending: false)
        .limit(200);
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

/// A report, its values and a way to show each one in context.
class LabReview {
  const LabReview({
    required this.upload,
    required this.results,
    required this.pageUrls,
  });

  final LabUpload upload;
  final List<BiomarkerResult> results;

  /// Signed URL per page index. Short-lived, and absent for a page whose
  /// object has gone missing — the values stay reviewable either way.
  final Map<int, String> pageUrls;
}

/// One file the user picked, already in memory.
class LabFile {
  const LabFile({required this.name, required this.extension, required this.bytes});

  final String name;
  final String extension;
  final Uint8List bytes;
}
