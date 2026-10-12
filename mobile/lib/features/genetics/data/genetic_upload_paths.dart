import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Where a genetics export goes, and what makes two uploads the same export.
///
/// Pure, and separate from the upload itself, because these are the rules the
/// storage policies and the database depend on — not an implementation detail
/// of a button. The sibling of `lab_upload_paths.dart`, with three
/// differences, each of which is in `019_genetic_ingest.sql` for a reason.

/// Its own bucket, not `lab-reports`. One per sensitivity class: a lab report
/// describes a person today, a genome describes them for life and partly
/// describes relatives who never consented to anything. Separate buckets mean
/// a policy mistake on one cannot reach the other.
const geneticsBucket = 'genetics';

/// Matches `storage.buckets.file_size_limit` for this bucket. Enforced there
/// too; this copy only exists so the app can say so before spending a user's
/// data allowance on an upload that will be rejected. An uncompressed 23andMe
/// export is around 15–25MB.
const maxGeneticUploadBytes = 30 * 1024 * 1024;

/// What the bucket's `allowed_mime_types` permits, as file extensions.
///
/// **No archives, deliberately.** 23andMe hands you a .zip and the obvious
/// thing is to accept it, but an archive from an untrusted source is a class
/// of problem we have no reason to take on for a file the user can
/// decompress themselves. The screen says so rather than failing on contact.
const allowedGeneticExtensions = {'txt', 'vcf', 'tsv'};

/// Both entries of the bucket's MIME allowlist resolve to this. Set
/// explicitly on upload: Supabase infers `application/octet-stream` for an
/// unfamiliar extension like .vcf, which the bucket then refuses.
const geneticsContentType = 'text/plain';

/// `{user_id}/{yyyy}/{upload_id}/raw.txt`
///
/// The first segment is the authorization boundary: the policies on
/// `storage.objects` compare `(storage.foldername(name))[1]` against
/// `auth.uid()`. Isolation is enforced by the storage layer rather than by
/// our code remembering to filter, and that only holds if the path is built
/// this way.
///
/// One file, not a prefix and an index: a lab report is pages, an export is
/// a single file, and `genetic_uploads.storage_path` is one path.
String geneticObjectPathFor({
  required String userId,
  required String uploadId,
  int? year,
}) {
  final y = year ?? DateTime.now().toUtc().year;
  return '$userId/$y/$uploadId/raw.txt';
}

bool isAllowedGeneticExtension(String extension) =>
    allowedGeneticExtensions.contains(extension.toLowerCase());

bool isWithinGeneticSizeCap(int bytes) => bytes <= maxGeneticUploadBytes;

/// Whether this looks like an archive the user should unzip first.
///
/// Separated from "not allowed" so the screen can say the useful thing. "zip
/// files cannot be read" invites somebody to give up; "unzip it first and
/// upload the .txt inside" is the same refusal with the answer attached.
bool looksLikeAnArchive(String extension) =>
    const {'zip', 'gz', 'tar', 'rar', '7z'}.contains(extension.toLowerCase());

/// The digest of the export, which is what makes
/// `genetic_uploads.content_sha256` unique per user mean "this genome twice".
///
/// Re-importing the same file does no harm to `genetic_variants`, whose
/// unique constraint absorbs it. What the constraint prevents is a second
/// copy of somebody's genome sitting in a bucket.
String geneticFileDigest(Uint8List bytes) => sha256.convert(bytes).toString();
